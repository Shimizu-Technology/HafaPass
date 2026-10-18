# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Transactional confirmation outbox" do
  it "cannot commit fulfillment without the confirmation journal" do
    event = create(:event, :published)
    type = create(:ticket_type, event: event)
    order = Commerce::OrderCreator.call(event: event, user: nil, buyer_name: "Fixture",
      buyer_email: "fixture@example.invalid", line_items: [{ ticket_type_id: type.id, quantity: 1 }], payment_required: true).order
    allow(EmailService).to receive(:send_order_confirmation_async).and_raise(ActiveRecord::RecordInvalid)
    expect { Commerce::OrderLifecycle.complete!(order) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(order.reload).to be_pending
    expect(order.tickets).to be_empty
  end

  it "creates one immutable confirmation intent for repeated completion and enqueue recovery" do
    order = create(:order, :completed)
    expect { 2.times { EmailService.send_order_confirmation_async(order) } }
      .to change { order.message_deliveries.count }.by(1)
    expect(order.message_deliveries.first.idempotency_key).to eq("order-confirmation/#{order.id}")
  end

  it "rolls back an event transition if any buyer notification intent cannot be journaled" do
    event = create(:event, :published)
    create(:order, :completed, event: event)
    allow(MessageDelivery).to receive(:find_or_create_by!).and_raise(StandardError, "journal unavailable")
    expect { EventLifecycle.call(event: event, action: :postpone, actor: event.organizer_profile.user, reason: "Fixture") }
      .to raise_error(StandardError, "journal unavailable")
    expect(event.reload).to be_published
    expect(event.event_changes).to be_empty
  end
end
