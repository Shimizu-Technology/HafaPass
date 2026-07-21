require "rails_helper"

RSpec.describe EventReminderJob, type: :job do
  let(:event) { create(:event, starts_at: 1.day.from_now) }
  let(:reminder) { create(:event_reminder, event: event, remind_at: 1.minute.ago) }

  it "uses durable idempotent delivery and marks sent only after provider dispatch" do
    described_class.perform_now(reminder.id, reminder.remind_at.iso8601)
    described_class.perform_now(reminder.id, reminder.remind_at.iso8601)

    expect(reminder.reload).to be_pending
    expect(MessageDelivery.where(template: "event_reminder").count).to eq(1)

    MessageDeliveryJob.perform_now(MessageDelivery.find_by!(template: "event_reminder").id)
    expect(reminder.reload).to be_sent
  end

  it "suppresses an enqueued delivery when the reminder is rescheduled" do
    described_class.perform_now(reminder.id, reminder.remind_at.iso8601)
    delivery = MessageDelivery.find_by!(template: "event_reminder")
    reminder.update!(remind_at: 2.hours.from_now)

    MessageDeliveryJob.perform_now(delivery.id)

    expect(delivery.reload).to be_suppressed
    expect(reminder.reload).to be_pending
  end
end
