require "rails_helper"

RSpec.describe SendEventChangeNotificationJob do
  it "cancels an existing delivery for a legacy cosmetic change without attempting a send" do
    order = create(:order)
    change = order.event.event_changes.create!(change_type: "rescheduled", occurred_at: Time.current)
    EventChange.where(id: change.id).update_all(change_type: "customized")
    delivery = create(:message_delivery, order: order, template: "event_change", attempts: 0)
    allow(EmailService).to receive(:send_event_change_notification)

    described_class.new.perform(change.id, order.id, delivery.id)

    expect(delivery.reload).to have_attributes(status: "cancelled", attempts: 0)
    expect(EmailService).not_to have_received(:send_event_change_notification)
  end
end
