require "rails_helper"
require "ostruct"

RSpec.describe EmailService, "guest privacy challenge" do
  it "sends synchronously without persisting the verification code or an email body" do
    order = create(:order)
    item = PrivacyRequest.create!(kind: "access", order: order, requester_email: order.buyer_email)
    code = item.issue_guest_challenge!
    allow(described_class).to receive(:configured?).and_return(false)
    expect(MessageDeliveryJob).not_to receive(:perform_later)

    delivery = described_class.send_guest_privacy_challenge_now(item, code)

    expect(item.reload.guest_challenge_digest).to eq(Digest::SHA256.hexdigest(code))
    expect(delivery.reload).to have_attributes(status: "sent", metadata: {}, outbound_payload: {},
      outbound_wire_body: nil)
    expect(delivery.attributes.to_json).not_to include(code)
  end

  it "passes the code only to the synchronous provider call" do
    order = create(:order)
    item = PrivacyRequest.create!(kind: "access", order: order, requester_email: order.buyer_email)
    code = item.issue_guest_challenge!
    allow(described_class).to receive(:configured?).and_return(true)
    allow(described_class).to receive(:transport_context_digest).and_return("transport-digest")
    allow(Resend::Emails).to receive(:send).and_return({ id: "provider-message-id" })

    delivery = described_class.send_guest_privacy_challenge_now(item, code)

    expect(Resend::Emails).to have_received(:send).with(hash_including("html" => include(code)),
      options: { idempotency_key: delivery.idempotency_key })
    expect(delivery.reload).to have_attributes(status: "sent", provider_id: "provider-message-id",
      metadata: {}, outbound_payload: {}, outbound_wire_body: nil)
    expect(delivery.attributes.to_json).not_to include(code)
  end
end

RSpec.describe EmailService do
  it "links a suspended buyer's reminder to their order instead of the hidden event" do
    buyer = create(:user)
    profile = create(:organizer_profile, verification_status: :verified)
    event = create(:event, :published, organizer_profile: profile, organization: profile.organization)
    order = create(:order, event: event, user: buyer, status: :completed)
    reminder = create(:event_reminder, event: event, user: buyer)
    allow(Rails.env).to receive(:production?).and_return(true)
    profile.update!(verification_status: :suspended)
    allow(described_class).to receive(:deliver)

    described_class.send_event_reminder(reminder)

    expect(described_class).to have_received(:deliver).with(hash_including(
      html: include("/orders/#{order.id}/confirmation", "View your order")))
    expect(described_class).not_to have_received(:deliver).with(hash_including(html: include("/events/#{event.slug}")))
  end

  it "links only currently public events from the verified decision email" do
    profile = create(:organizer_profile, verification_status: :verified)
    public_event = create(:event, :published, organizer_profile: profile, organization: profile.organization)
    held_event = create(:event, :published, organizer_profile: profile, organization: profile.organization,
      policy_hold_at: Time.current, policy_hold_scope: "hidden")
    allow(Rails.env).to receive(:production?).and_return(true)
    delivery = OpenStruct.new(metadata: { "status" => "verified", "note" => "" }, recipient: "owner@example.com")
    allow(described_class).to receive(:deliver)

    described_class.send_verification_decision(profile, delivery: delivery)

    expect(described_class).to have_received(:deliver).with(hash_including(html: include(
      "/events/#{public_event.slug}", "Some events need attention", "/dashboard")))
    expect(described_class).not_to have_received(:deliver).with(hash_including(html: include("/events/#{held_event.slug}")))
  end

  it "cancels a queued waitlist offer email when its public event becomes hidden" do
    profile = create(:organizer_profile, verification_status: :verified)
    event = create(:event, :published, organizer_profile: profile, organization: profile.organization)
    ticket_type = create(:ticket_type, event: event)
    entry = create(:waitlist_entry, event: event, ticket_type: ticket_type)
    offer = create(:waitlist_offer, event: event, ticket_type: ticket_type, waitlist_entry: entry)
    delivery = create(:message_delivery, event: event, template: "waitlist_offer",
      metadata: { waitlist_offer_id: offer.id })
    allow(Rails.env).to receive(:production?).and_return(true)
    profile.update!(verification_status: :suspended)
    allow(described_class).to receive(:prepare_delivery_payload)

    MessageDeliveryJob.new.perform(delivery.id)

    expect(delivery.reload).to be_cancelled
    expect(described_class).not_to have_received(:prepare_delivery_payload)
  end

  it "groups large USD amounts in English and localized receipt emails" do
    order = create(:order, subtotal_cents: 1_000_00, service_fee_cents: 11_345_67, total_cents: 12_345_67)
    english = I18n.with_locale(:en) { described_class.send(:build_order_confirmation_html, order, order.event, []) }
    korean = I18n.with_locale(:ko) { described_class.send(:build_order_confirmation_html, order, order.event, []) }

    expect(english).to include("$1,000.00", "$12,345.67")
    expect(korean).to include("US$1,000.00", "US$12,345.67")
    expect(english).not_to include("$1000.00", "$12345.67")
  end

  it "rejects an unprepared direct delivery before networking" do
    order = create(:order, user: nil)
    delivery = create(:message_delivery, order: order)
    original = order.attributes
    allow(described_class).to receive(:configured?).and_return(true)
    allow(Resend::Emails).to receive(:send)
    expect { described_class.send_order_confirmation(delivery.order, delivery: delivery) }
      .to raise_error(described_class::TransportContextChanged)
    expect(Resend::Emails).not_to have_received(:send)
    expect(delivery.reload).to have_attributes(attempts: 0, outbound_wire_body: nil, provider_id: nil)
    expect(order.reload.attributes).to eq(original)
  end

  it "rejects real transport without a journal" do
    allow(described_class).to receive(:configured?).and_return(true)
    allow(Resend::Emails).to receive(:send)
    expect { described_class.send_order_confirmation(create(:order)) }
      .to raise_error(MessageWirePayload::Unavailable, /durable MessageDelivery/)
    expect(Resend::Emails).not_to have_received(:send)
  end

  it "freezes the configured reply mailbox with the original provider payload across a lost response" do
    delivery = create(:message_delivery)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("MAILER_REPLY_TO").and_return(" operator@example.test ")
    allow(described_class).to receive(:configured?).and_return(true)
    captured = []
    allow(Resend::Emails).to receive(:send) do |params, options:|
      captured << [params.deep_dup, options.deep_dup]
      raise "provider response lost" if captured.length == 1

      { id: "synthetic-provider-email" }
    end

    expect { MessageDeliveryJob.new.perform(delivery.id) }.to raise_error("provider response lost")
    original = delivery.reload.outbound_payload.deep_dup
    original_digest = delivery.payload_digest
    expect(original.fetch("reply_to")).to eq("operator@example.test")
    allow(ENV).to receive(:[]).with("MAILER_REPLY_TO").and_return("new-operator@example.test")
    MessageDeliveryJob.new.perform(delivery.id)

    expect(captured[0]).to eq(captured[1])
    expect(captured[1][0].fetch("reply_to")).to eq("operator@example.test")
    expect(captured[1][1]).to eq(idempotency_key: delivery.idempotency_key)
    expect(delivery.reload.outbound_payload).to eq(original)
    expect(delivery.payload_digest).to eq(original_digest)
  end

  [nil, "", "   "].each do |value|
    it "omits optional reply-to when configured as #{value.inspect}" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("MAILER_REPLY_TO").and_return(value)
      payload = described_class.prepare_delivery_payload(create(:message_delivery))
      expect(payload).not_to have_key("reply_to")
    end
  end

  describe ".from_email" do
    def stub_sender(value)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("MAILER_FROM_EMAIL").and_return(value)
    end

    it "uses the configured verified sender" do
      stub_sender(" HåfaPass <tickets@mail.example.test> ")
      expect(described_class.from_email).to eq("HåfaPass <tickets@mail.example.test>")
    end

    it "falls back to a reserved domain only in development and test" do
      stub_sender(nil)
      expect(described_class.from_email).to eq("tickets@example.test")
    end

    it "refuses to send from a deployed environment without a configured sender" do
      stub_sender("")
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("staging"))
      allow(described_class).to receive(:configured?).and_return(true)

      expect { described_class.from_email }.to raise_error(described_class::ProviderDisabled, /MAILER_FROM_EMAIL/)
    end
  end

  it "explains transferred tickets instead of an empty ticket table when the buyer holds none" do
    order = create(:order)
    html = described_class.send(:build_order_confirmation_html, order, order.event, [])

    expect(html).to include("All tickets on this order were transferred")
    expect(html).not_to include("Your Tickets")
    expect(html).not_to include("Present your QR code")
  end

  it "names the organizer as seller and the platform as the ticketing service on receipts and tickets" do
    ticket = create(:ticket)
    seller = ticket.event.organizer_profile.business_name
    receipt = described_class.send(:build_order_confirmation_html, ticket.order, ticket.event, [ticket])
    ticket_html = described_class.send(:build_ticket_email_html, ticket, ticket.event, ticket.ticket_type)

    expect(receipt).to include("Sold by #{ERB::Util.html_escape(seller)} · Tickets by HåfaPass",
      "Event seller: #{ERB::Util.html_escape(seller)}", "operated by ", "Shimizu Technology", "Service fee:", "Total paid:")
    expect(receipt).not_to match(/tax/i)
    expect(ticket_html).to include("Sold by #{ERB::Util.html_escape(seller)} · Tickets by HåfaPass")
  end

  it "keeps the ticket table and validity instructions while the buyer holds tickets" do
    ticket = create(:ticket)
    html = described_class.send(:build_order_confirmation_html, ticket.order, ticket.event, [ticket])

    expect(html).to include("Your Tickets", "Only valid tickets can be used for entry.", "View your order")
    expect(html).not_to include("were transferred")
  end

  it "fails closed in production instead of recording a simulated customer delivery" do
    order = create(:order)
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(PlatformCapabilities).to receive(:enabled?).with("resend_production").and_return(false)

    expect do
      described_class.send_order_confirmation(order)
    end.to raise_error(described_class::ProviderDisabled, /disabled until current Resend evidence/)
  end

  it "labels an unapproved production delivery as disabled for support visibility" do
    order = create(:order)
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(PlatformCapabilities).to receive(:enabled?).with("resend_production").and_return(false)
    allow(MessageDeliveryJob).to receive(:perform_later)

    delivery = described_class.send_order_confirmation_async(order)

    expect(delivery.provider).to eq("disabled")
  end

  it "passes a stable provider idempotency key and escapes all organizer and attendee HTML" do
    order = create(:order, buyer_name: "<script>buyer()</script>")
    order.event.update!(title: "<img src=x onerror=alert(1)>", venue_name: "<b>Venue</b>")
    ticket_type = create(:ticket_type, event: order.event, name: "<svg onload=alert(2)>")
    create(:ticket, order: order, event: order.event, ticket_type: ticket_type,
      attendee_name: "<em>Attendee</em>")
    delivery = create(:message_delivery, order: order, event: order.event)
    captured = nil
    allow(described_class).to receive(:configured?).and_return(true)
    allow(Resend::Emails).to receive(:send) do |params, options:|
      captured = [params, options]
      { id: "provider-email" }
    end

    MessageDeliveryJob.new.perform(delivery.id)

    params, options = captured
    expect(options).to eq(idempotency_key: delivery.idempotency_key)
    expect(params["html"]).to include("&lt;script&gt;buyer()&lt;/script&gt;", "&lt;img src=x onerror=alert(1)&gt;",
      "&lt;b&gt;Venue&lt;/b&gt;", "&lt;svg onload=alert(2)&gt;", "&lt;em&gt;Attendee&lt;/em&gt;")
    expect(params["html"]).not_to include("<script>buyer()", "<img src=x", "<svg onload")
  end

  it "leaves tickets transferred to another account out of the buyer's order email" do
    buyer = create(:user)
    order = create(:order, user: buyer)
    ticket_type = create(:ticket_type, event: order.event)
    held = create(:ticket, order: order, event: order.event, ticket_type: ticket_type, attendee_name: "Held Guest")
    moved = create(:ticket, order: order, event: order.event, ticket_type: ticket_type, attendee_name: "Transferee Guest")
    moved.update!(holder_user: create(:user))
    expect([held, moved].map(&:display_credential)).to all(be_present)

    html = described_class.prepare_delivery_payload(create(:message_delivery, order: order)).fetch("html")

    expect(html).to include("Held Guest", "/tickets/#{held.display_credential}")
    expect(html).not_to include("Transferee Guest", moved.display_credential)
  end
end
