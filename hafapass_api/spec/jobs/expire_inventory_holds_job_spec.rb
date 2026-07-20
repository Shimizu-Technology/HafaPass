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
end
