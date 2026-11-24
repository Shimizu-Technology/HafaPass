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
    order = create(:order, buyer_name: "x" * 121)
    CheckoutSubscriptionJob.perform_now(order.id)
    expect(PlatformSubscriber.find_by!(email: order.buyer_email).name.length).to eq(120)
    allow(PlatformSubscription).to receive(:call).and_raise(ActiveRecord::RecordInvalid)
    expect(Rails.logger).to receive(:warn).with(/Platform subscription skipped/)
    expect { CheckoutSubscriptionJob.perform_now(order.id) }.not_to raise_error
  end
end
