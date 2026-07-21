require "rails_helper"

RSpec.describe ExpireInventoryHoldsJob do
  it "releases every due order idempotently" do
    order = create(:order, :pending, expires_at: 1.minute.ago)
    item = create(:order_item, order: order)
    hold = create(:inventory_hold, order: order, order_item: item, expires_at: 1.minute.ago)

    expect do
      described_class.perform_now(Time.current)
    end.to change { order.reload.status }.from("pending").to("expired")
      .and change { hold.reload.status }.from("active").to("expired")

    expect do
      described_class.perform_now(Time.current)
    end.not_to change { [order.reload.status, hold.reload.status] }
  end

  it "requeues expired waitlist offers and closes stale transfer invitations" do
    event = create(:event, :published)
    type = create(:ticket_type, event: event)
    entry = create(:waitlist_entry, event: event, ticket_type: type, status: :offered)
    offer = create(:waitlist_offer, waitlist_entry: entry, event: event, ticket_type: type,
      expires_at: 1.minute.ago)
    order = create(:order, event: event)
    item = create(:order_item, order: order, ticket_type: type)
    ticket = create(:ticket, order: order, event: event, ticket_type: type, order_item: item)
    transfer = create(:ticket_transfer, ticket: ticket, expires_at: 1.minute.ago)

    described_class.perform_now(Time.current)

    expect(offer.reload).to be_expired
    expect(entry.reload).to be_waiting
    expect(transfer.reload).to be_expired
  end
end
