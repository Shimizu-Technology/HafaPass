require "rails_helper"

RSpec.describe CheckoutSubscriptionJob do
  include ActiveSupport::Testing::TimeHelpers
  include ActiveJob::TestHelper

  ["true", "false"].each do |confirmation|
    it "preserves a later withdrawal when confirmation is #{confirmation}" do
      stub_const("ENV", ENV.to_h.merge("EMAIL_DOUBLE_OPT_IN" => confirmation))
      order = create(:order)
      subscriber = PlatformSubscriber.create!(email: order.buyer_email, source: "footer", status: "confirmed")
      consent_at = Time.current.iso8601(6)
      described_class.perform_later(order.id, consent_at: consent_at)
      travel 1.minute do
        EmailPreferences.unsubscribe_platform!(subscriber.email)
        expect { perform_enqueued_jobs(only: described_class) }.not_to change(MessageDelivery, :count)
      end
      expect(subscriber.reload.status).to eq("unsubscribed")
      expect(EmailConsent.where(email: subscriber.email).pluck(:action)).to eq(["unsubscribed"])
    end
  end

  it "accepts checkout consent newer than the withdrawal" do
    order = create(:order)
    EmailPreferences.unsubscribe_platform!(order.buyer_email)
    travel 1.minute do
      described_class.perform_now(order.id, consent_at: Time.current.iso8601(6))
    end
    expect(PlatformSubscriber.find_by!(email: order.buyer_email).status).to eq("pending")
    expect(MessageDelivery.where(template: "platform_confirmation").count).to eq(1)
  end
end
