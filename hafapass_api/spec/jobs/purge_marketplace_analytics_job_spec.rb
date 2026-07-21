require "rails_helper"

RSpec.describe PurgeMarketplaceAnalyticsJob do
  it "removes expired anonymous activity while retaining purchase evidence" do
    event = create(:event)
    old = MarketplaceFunnelEvent.create!(event: event, visitor_hash: "a" * 64, stage: :event_view,
      occurred_at: 14.months.ago)
    order = create(:order, event: event)
    purchase = MarketplaceFunnelEvent.create!(event: event, order: order, visitor_hash: "b" * 64, stage: :purchase,
      occurred_at: 14.months.ago)

    described_class.perform_now

    expect(MarketplaceFunnelEvent.exists?(old.id)).to be(false)
    expect(MarketplaceFunnelEvent.exists?(purchase.id)).to be(true)
  end
end
