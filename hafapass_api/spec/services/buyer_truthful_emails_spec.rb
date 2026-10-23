require "rails_helper"

RSpec.describe "Buyer email states", :webmock do
  let(:event) { create(:event, :published, starts_at: 5.days.from_now) }
  let(:order) { create(:order, event: event) }
  let(:ticket_type) { create(:ticket_type, event: event) }

  def ticket_for_order(**attributes)
    create(:ticket, order: order, event: event, ticket_type: ticket_type, **attributes)
  end

  def confirmation(template: "order_confirmation")
    EmailService.prepare_delivery_payload(create(:message_delivery, order: order, template: template))
  end

  def refund_payload(refund)
    delivery = EmailService.send_refund_notification_async(order, refund: refund)
    expect(delivery.metadata).to eq("refund_id" => refund.id)
    expect(delivery.idempotency_key).to eq("refund-notification/#{refund.id}")
    EmailService.prepare_delivery_payload(delivery)
  end

  it "uses the same signed guest order access for every confirmation link" do
    ticket_for_order
    html = confirmation.fetch("html")
    anchors = Nokogiri::HTML(html).css("a")
    expect(anchors.map(&:text)).to eq(["View your order", "View your order"])
    links = anchors.map { |link| URI.parse(link["href"]) }

    expect(links.length).to eq(2)
    expect(links.map(&:to_s).uniq.length).to eq(1)
    expect(links.first.path).to eq("/orders/#{order.id}/confirmation")
    token = Rack::Utils.parse_query(links.first.query).fetch("guest_token")
    expect(GuestOrderAccess.find(token)).to eq(order)
    expect(html).not_to include("My Tickets", "/my-tickets", "/tickets/")
  end

  it "keeps My Tickets and individual ticket links for account buyers" do
    order.update!(user: create(:user))
    ticket = ticket_for_order
    html = confirmation.fetch("html")

    expect(html).to include("My Tickets", "/my-tickets", "/tickets/#{ticket.display_credential}")
    expect(Nokogiri::HTML(html).at_css("td a").text).to eq("View Ticket")
    expect(html).not_to include("guest_token=")
    expect(order.reload.guest_access_expires_at).to be_nil
  end

  it "uses guest order access in partial PDF notes without implying every ticket admits" do
    stub_const("ENV", ENV.to_h.merge("PUBLIC_API_URL" => "https://api.hafapass.test"))
    ticket_for_order(attendee_name: "Valid Guest")
    ticket_for_order(status: :cancelled, attendee_name: "Cancelled Guest")
    payload = confirmation(template: "fulfillment_resend")

    expect(payload.fetch("attachments").length).to eq(1)
    expect(payload.fetch("html")).to include("1 of your 2 tickets are attached", "View your order",
      "The others can&#39;t be used for entry right now")
    expect(payload.fetch("html")).not_to include("/my-tickets")
  end

  it "shows current states on resends including cancelled and checked-in tickets" do
    order.update!(status: :partially_refunded, refund_amount_cents: 1000)
    ticket_for_order(status: :issued, attendee_name: "Current Guest")
    ticket_for_order(status: :cancelled, attendee_name: "Refunded Guest")
    ticket_for_order(status: :checked_in, attendee_name: "Admitted Guest")
    moved = ticket_for_order(holder_user: create(:user), attendee_name: "New Holder")
    payload = confirmation(template: "fulfillment_resend")
    html = payload.fetch("html")

    expect(payload.fetch("subject")).to eq("Your current HåfaPass order details - #{event.title}")
    expect(html).to include("Your current order details", "Status", "Issued", "Cancelled", "Checked in",
      "Current Guest", "Refunded Guest", "Admitted Guest", "Only valid tickets can be used for entry.")
    expect(html).not_to include("Your tickets are confirmed!", "Order Confirmed", "New Holder", moved.display_credential)
  end

  it "uses current order wording even when every ticket on a resend is valid" do
    ticket_for_order
    html = confirmation(template: "fulfillment_resend").fetch("html")
    expect(html).to include("Your current order details")
    expect(html).not_to include("Your tickets are confirmed!")
  end

  it "does not confirm invalid tickets when the original email was delayed" do
    ticket_for_order(status: :cancelled)
    html = confirmation.fetch("html")
    expect(html).to include("Your current order details")
    expect(html).not_to include("Your tickets are confirmed!")
  end

  it "keeps two queued partial refund emails tied to their own amounts and reasons" do
    first = create(:refund, order: order, amount_cents: 1000, reason: "First adjustment")
    first_delivery = EmailService.send_refund_notification_async(order, refund: first)
    second = create(:refund, order: order, payment: first.payment, amount_cents: 1500, reason: "Second adjustment")
    second_delivery = EmailService.send_refund_notification_async(order, refund: second)
    order.update!(status: :partially_refunded, refund_amount_cents: 2500, refund_reason: second.reason)

    expect(first_delivery.metadata).to eq("refund_id" => first.id)
    expect(second_delivery.metadata).to eq("refund_id" => second.id)
    first_html = EmailService.prepare_delivery_payload(first_delivery).fetch("html")
    second_html = EmailService.prepare_delivery_payload(second_delivery).fetch("html")
    expect(first_html).to include("Partial refund ($10.00)", "First adjustment")
    expect(first_html).not_to include("$15.00", "$25.00", "Second adjustment")
    expect(second_html).to include("Partial refund ($15.00)", "Second adjustment")
    expect(second_html).not_to include("$10.00", "$25.00", "First adjustment")
  end

  it "does not substitute cumulative totals for missing, foreign, or unsuccessful refunds" do
    order.update!(refund_amount_cents: 2500)
    delivery = create(:message_delivery, order: order, template: "refund_notification")
    expect { EmailService.prepare_delivery_payload(delivery) }.to raise_error(MessageWirePayload::Unavailable)

    foreign = create(:refund)
    failed = create(:refund, order: order, status: :failed)
    [foreign, failed].each do |refund|
      delivery.update!(metadata: { refund_id: refund.id })
      expect { EmailService.prepare_delivery_payload(delivery) }.to raise_error(ActiveRecord::RecordNotFound)
      expect { EmailService.send_refund_notification_async(order, refund: refund) }.to raise_error(ArgumentError)
    end
  end

  it "qualifies Stripe card refund timing with bank and issuer variability" do
    html = refund_payload(create(:refund, order: order, amount_cents: 1000)).fetch("html")
    expect(html).to include("Your refund of $10.00 usually appears on your original card within 5–10 business days, depending on your bank or card issuer.")
    expect(html).not_to include("will be returned", "within 5-10")
  end

  it "does not promise card timing for organizer-returned cash" do
    order.update!(payment_method: "door_cash")
    html = refund_payload(create(:refund, order: order, provider: "door_cash", amount_cents: 1000)).fetch("html")
    expect(html).to include("recorded a cash return of $10.00")
    expect(html).not_to include("business days", "original card", "on its way")
  end

  it "keeps manual door-card returns distinct from automated Stripe refunds after cancellation" do
    event.update!(status: :cancelled)
    order.update!(payment_method: "door_card")
    html = refund_payload(create(:refund, order: order, provider: "boh_clover", amount_cents: 1000)).fetch("html")
    expect(html).to include("recorded a card refund of $10.00", "Contact the organizer about when it will appear on your card.")
    expect(html).not_to include("business days", "original card", "on its way", "including service fees")
  end

  it "falls back to truthful English for changed copy in every translated locale" do
    with_locales_enabled(AppLocale::SUPPORTED)
    ticket_for_order(status: :cancelled)
    refund = create(:refund, order: order, amount_cents: 1000)
    AppLocale::TRANSLATION_TARGETS.each do |locale|
      order.update!(locale: locale)
      html = confirmation(template: "fulfillment_resend").fetch("html")
      expect(html).to include("Your current order details", "Only valid tickets can be used for entry.", "Cancelled", "View your order")
      expect(refund_payload(refund).fetch("html"))
        .to include("usually appears on your original card within 5–10 business days, depending on your bank or card issuer.")
    end
  end

  %w[partially_completed completed].each do |status|
    it "accurately describes a #{status} privacy deletion request" do
      request = PrivacyRequest.create!(kind: "deletion", status: status, order: order, requester_email: order.buyer_email)
      delivery = create(:message_delivery, order: order, privacy_request: request, template: "privacy_request_confirmation")
      payload = EmailService.prepare_delivery_payload(delivery)
      if status == "partially_completed"
        expect(payload.fetch("subject")).to eq("Update on your HåfaPass privacy request")
        expect(payload.fetch("html")).to include("Some information still needs to be removed from connected services. HåfaPass support will follow up.")
        expect(payload.fetch("html")).not_to include("is complete", "provider cleanup", "manual completion")
      else
        expect(payload.fetch("subject")).to eq("Your HåfaPass privacy request is complete")
        expect(payload.fetch("html")).not_to include("Some information still needs to be removed")
      end
    end
  end
end
