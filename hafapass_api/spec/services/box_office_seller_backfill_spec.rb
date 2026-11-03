require "rails_helper"
require Rails.root.join("db/migrate/20261104000100_backfill_box_office_sellers")

RSpec.describe BackfillBoxOfficeSellers do
  it "removes staff ownership, preserves transferred holders and can run twice" do
    seller = create(:user)
    recipient = create(:user)
    order = create(:order, source: "box_office", user: seller)
    original = create(:ticket, order: order, event: order.event, holder_user: seller)
    transferred = create(:ticket, order: order, event: order.event, holder_user: recipient)

    2.times { described_class.new.up }

    expect(order.reload).to have_attributes(user_id: nil, sold_by_id: seller.id)
    expect(original.reload.holder_user_id).to be_nil
    expect(transferred.reload.holder_user).to eq(recipient)
    expect(GuestOrderAccess.find(GuestOrderAccess.issue!(order))).to eq(order)
  end
end
