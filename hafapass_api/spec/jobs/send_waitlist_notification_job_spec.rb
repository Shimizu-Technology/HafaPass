require "rails_helper"

RSpec.describe SendWaitlistNotificationJob do
  it "does not queue an alert for an entry returned to waiting" do
    entry = create(:waitlist_entry)
    allow(EmailService).to receive(:send_waitlist_notification_async)
    described_class.perform_now(entry.id)
    expect(EmailService).not_to have_received(:send_waitlist_notification_async)
  end

  it "queues an alert for a notified entry" do
    event = create(:event)
    event.organization.update!(marketing_mailing_address: "123 Marine Drive, Hagåtña, GU 96910",
      marketing_address_certified_at: Time.current)
    entry = create(:waitlist_entry, event: event)
    entry.notify!
    allow(EmailService).to receive(:send_waitlist_notification_async)
    described_class.perform_now(entry.id)
    expect(EmailService).to have_received(:send_waitlist_notification_async).with(entry)
  end
  it "returns a failed enqueue to waiting with a visible reason" do
    event = create(:event)
    event.organization.update!(marketing_mailing_address: "123 Marine Drive, Hagåtña, GU 96910",
      marketing_address_certified_at: Time.current)
    entry = create(:waitlist_entry, event: event)
    entry.notify!
    allow(EmailService).to receive(:send_waitlist_notification_async).and_raise(StandardError, "queue unavailable")
    described_class.perform_now(entry.id)
    expect(entry.reload).to be_waiting
    expect(entry.delivery_failure).to include("queue unavailable")
  end
end
