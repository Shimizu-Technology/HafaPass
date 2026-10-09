require "rails_helper"

RSpec.describe EmailService do
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

    described_class.send_order_confirmation(order, delivery: delivery)

    params, options = captured
    expect(options).to eq(idempotency_key: delivery.idempotency_key)
    expect(params[:html]).to include("&lt;script&gt;buyer()&lt;/script&gt;", "&lt;img src=x onerror=alert(1)&gt;",
      "&lt;b&gt;Venue&lt;/b&gt;", "&lt;svg onload=alert(2)&gt;", "&lt;em&gt;Attendee&lt;/em&gt;")
    expect(params[:html]).not_to include("<script>buyer()", "<img src=x", "<svg onload")
  end
end
