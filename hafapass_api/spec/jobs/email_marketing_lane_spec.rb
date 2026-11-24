require "rails_helper"

RSpec.describe "Marketing dispatch lane", type: :job do
  it "P7: serializes provider requests once without per-recipient re-enqueues", :email_rate_limit do
    allow(EmailRateSlot).to receive(:sleep) do |seconds|
      expect(seconds).to be >= 0
    end
    results = 4.times.map { |i| EmailRateSlot.dispatch! { i } }
    expect(results).to eq([0, 1, 2, 3])
    expect(EmailRateSlot).to have_received(:sleep).exactly(4).times
  end

  it "B1: sends an order confirmation immediately with a marketing blast queued and backed off" do
    order = create(:order, :completed)
    admin = create(:user, role: :admin)
    mailing = AudienceMailing.create!(created_by: admin, subject: "Blast", body: "Shows", audience: "platform")
    100.times do |i|
      delivery = mailing.delivery("subscriber#{i}@example.test")
      delivery.save!
      expect(MessageDeliveryJob.new(delivery.id).queue_name).to eq("marketing")
    end
    EmailRateSlot.create!(name: "resend", available_at: 1.hour.from_now)
    EmailRateSlot.backoff!
    allow(EmailService).to receive(:configured?).and_return(false)
    delivery = MessageDelivery.create!(order: order, channel: "email", template: "order_confirmation", recipient: order.buyer_email, provider: "simulated")
    expect(MessageDeliveryJob.new(delivery.id).queue_name).to eq("emails")
    expect(EmailRateSlot).not_to receive(:dispatch!)
    MessageDeliveryJob.perform_now(delivery.id)
    expect(delivery.reload.status).to eq("sent")
    expect(delivery.attempts).to eq(1)
    %w[waitlist_offer waitlist_notification ticket_transfer refund_notification ticket_delivery].each do |template|
      priority = MessageDelivery.create!(order: order, channel: "email", template: template, recipient: order.buyer_email, provider: "simulated")
      expect(MessageDeliveryJob.new(priority.id).queue_name).to eq("emails")
      expect(priority.bulk_marketing?).to be(false)
    end
  end

  it "P1: normalizes a checkout subscriber name and logs a failed optional write" do
    order = create(:order, buyer_name: "x" * 121, platform_opt_in_at: Time.current)
    CheckoutSubscriptionJob.perform_now(order.id, consent_at: Time.current.iso8601(6))
    expect(PlatformSubscriber.find_by!(email: order.buyer_email).name.length).to eq(120)
    allow(PlatformSubscription).to receive(:call).and_raise(ActiveRecord::RecordInvalid)
    expect(Rails.logger).to receive(:warn).with(/Platform subscription skipped/)
    expect { CheckoutSubscriptionJob.perform_now(order.id, consent_at: Time.current.iso8601(6)) }.not_to raise_error
  end
  it "N1: schedules a transactional 429 retry without touching bulk backoff" do
    order = create(:order, :completed)
    message = create(:message_delivery, order: order, template: "order_confirmation")
    allow(EmailService).to receive(:send_delivery_payload).and_raise(Resend::Error::RateLimitExceededError.new("rate limited"))
    expect(EmailRateSlot).not_to receive(:backoff!)
    expect { MessageDeliveryJob.perform_now(message.id) }.to have_enqueued_job(MessageDeliveryJob)
    expect(message.reload.status).to eq("failed")
  end

  it "N3: retains bounded checkout request evidence in the consent ledger" do
    order = create(:order, platform_opt_in_at: Time.current)
    CheckoutSubscriptionJob.perform_now(order.id, consent_at: Time.current.iso8601(6), ip: "203.0.113.24", user_agent: "x" * 600)
    consent = EmailConsent.find_by!(email: order.buyer_email, action: "requested")
    expect(consent).to have_attributes(ip: "203.0.113.24", user_agent: "x" * 500, source: "checkout")
  end

  it "N5: prioritizes self-tests and double opt-in ahead of bulk blasts" do
    mailing = AudienceMailing.create!(created_by: create(:user, role: :admin), subject: "Test", body: "Shows", audience: "platform")
    message = mailing.delivery("test@example.test", test: true)
    message.save!
    expect(message.template).to eq("audience_test")
    expect(MessageDeliveryJob.new(message.id).queue_name).to eq("emails")
    expect(message.bulk_marketing?).to be(false)
    expect(CheckoutSubscriptionJob.new(1).queue_name).to eq("default")
    subscriber = PlatformSubscription.call({ email: "priority@example.test", source: "checkout" })
    confirmation = subscriber.message_deliveries.sole
    expect(MessageDeliveryJob.new(confirmation.id).queue_name).to eq("emails")
  end
end
