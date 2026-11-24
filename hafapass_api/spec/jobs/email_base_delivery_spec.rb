require "rails_helper"

RSpec.describe "Audience email delivery", type: :job do
  include ActiveSupport::Testing::TimeHelpers
  let(:admin) { create(:user, role: :admin) }
  let(:email) { "alerts@example.test" }
  let(:mailing) { AudienceMailing.create!(created_by: admin, subject: "Events", body: "On Guam", audience: "platform", status: "scheduled", scheduled_at: Time.current) }

  before do
    allow(EmailService).to receive(:configured?).and_return(false)
    stub_const("ENV", ENV.to_h.merge("HAFAPASS_POSTAL_ADDRESS" => "TEST FIXTURE ADDRESS — no delivery"))
    PlatformSubscriber.create!(email: email, source: "footer", status: "confirmed")
  end

  it "queues once, freezes the exact footer, and rechecks unsubscribe before delivery" do
    AudienceMailingJob.perform_now(mailing.id)
    expect(mailing.message_deliveries.count).to eq(1)
    AudienceMailingJob.perform_now(mailing.id)
    expect(mailing.message_deliveries.count).to eq(1)
    delivery = mailing.message_deliveries.first
    MessageDeliveryJob.perform_now(delivery.id)
    expect(delivery.reload.status).to eq("sent")
    expect(delivery.outbound_payload["html"]).to include("TEST FIXTURE ADDRESS", "Email preferences")
    expect(delivery.outbound_payload["headers"]["List-Unsubscribe-Post"]).to eq("List-Unsubscribe=One-Click")
    MessageDeliveryJob.perform_now(delivery.id)
    expect(delivery.reload.attempts).to eq(1)
    second = mailing.dup
    second.status = "scheduled"
    second.save!
    AudienceMailingJob.perform_now(second.id)
    EmailPreferences.unsubscribe_platform!(email)
    MessageDeliveryJob.perform_now(second.message_deliveries.first.id)
    expect(second.message_deliveries.first.status).to eq("suppressed")
  end

  it "excludes complaints and global suppressions from live counts" do
    EmailPreference.create!(email: email, all_unsubscribed: true)
    expect(mailing.audience_emails).to be_empty
    EmailPreference.delete_all
    order = create(:order)
    MessageDelivery.create!(order: order, recipient: email, channel: "email", template: "communication_campaign", provider: "simulated", status: :complained)
    expect(mailing.audience_emails).to be_empty
  end

  it "rechecks postal address and actor permission at dispatch" do
    AudienceMailingJob.perform_now(mailing.id)
    admin.update!(role: :attendee)
    MessageDeliveryJob.perform_now(mailing.message_deliveries.first.id)
    expect(mailing.message_deliveries.first.status).to eq("suppressed")
  end

  it "atomically paces requests and backs off after provider throttling", :email_rate_limit do
    expect(EmailRateSlot.reserve!).to eq(0)
    expect(EmailRateSlot.reserve!).to be > 0
    travel 4.seconds do
      expect(EmailRateSlot.reserve!).to eq(0)
      EmailRateSlot.backoff!
      expect(EmailRateSlot.reserve!).to be > 29
    end
  end
end

RSpec.describe "Audience address withdrawal", type: :job do
  it "suppresses dispatch when the postal address is withdrawn while the actor remains authorized" do
    stub_const("ENV", ENV.to_h.merge("HAFAPASS_POSTAL_ADDRESS" => "TEST ADDRESS"))
    allow(EmailService).to receive(:configured?).and_return(false)
    admin = create(:user, role: :admin)
    PlatformSubscriber.create!(email: "address@example.test", source: "footer", status: "confirmed")
    mailing = AudienceMailing.create!(created_by: admin, subject: "Events", body: "Fixture", audience: "platform", status: "scheduled", scheduled_at: Time.current)
    AudienceMailingJob.perform_now(mailing.id)
    ENV.delete("HAFAPASS_POSTAL_ADDRESS")
    expect(EmailService).not_to receive(:send_delivery_payload)
    MessageDeliveryJob.perform_now(mailing.message_deliveries.first.id)
    expect(mailing.message_deliveries.first.status).to eq("suppressed")
    expect(mailing.authorized?).to be(true)
  end
end

RSpec.describe "Blocked audience dispatch", type: :job do
  it "does not send a snapshotted delivery after a blocked mailing regains its address" do
    stub_const("ENV", ENV.to_h.merge("HAFAPASS_POSTAL_ADDRESS" => "TEST ADDRESS"))
    allow(EmailService).to receive(:configured?).and_return(false)
    admin = create(:user, role: :admin)
    PlatformSubscriber.create!(email: "blocked@example.test", source: "footer", status: "confirmed")
    mailing = AudienceMailing.create!(created_by: admin, subject: "Events", body: "Fixture", audience: "platform", status: "scheduled", scheduled_at: Time.current)
    AudienceMailingJob.perform_now(mailing.id)
    mailing.update!(status: "blocked", blocked_reason: "Address unavailable")
    expect(EmailService).not_to receive(:send_delivery_payload)
    MessageDeliveryJob.perform_now(mailing.message_deliveries.first.id)
    expect(mailing.message_deliveries.first.status).to eq("suppressed")
  end
end
