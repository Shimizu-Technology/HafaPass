require "rails_helper"

RSpec.describe PurgeMarketplaceAnalyticsJob do
  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("DATA_RETENTION_DESTRUCTIVE_ENABLED").and_return("true")
    SiteSetting.instance.update_columns(retention_purge_enabled: true)
  end

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

  it "purges a 14-month-old unlinked event with the deploy flag unset" do
    allow(ENV).to receive(:[]).with("DATA_RETENTION_DESTRUCTIVE_ENABLED").and_return(nil)
    SiteSetting.instance.update_columns(retention_purge_enabled: false)
    event = create(:event)
    old = MarketplaceFunnelEvent.create!(event: event, visitor_hash: "d" * 64, stage: :event_view,
      occurred_at: 14.months.ago)

    described_class.perform_now

    expect(MarketplaceFunnelEvent.exists?(old.id)).to be(false)
  end

  it "rechecks a hold under the row lock after the initial scan" do
    event = create(:event)
    old = MarketplaceFunnelEvent.create!(event: event, visitor_hash: "c" * 64, stage: :event_view,
      occurred_at: 14.months.ago)
    checks = 0
    allow(RetentionGuard).to receive(:protected?).and_wrap_original do |original, record|
      result = original.call(record)
      if record == old && (checks += 1) == 1
        LegalHold.place!(scope_type: "event", scope_value: event.id.to_s,
          reason: "Preserve analytics evidence", actor: create(:user, :admin))
      end
      result
    end

    described_class.perform_now

    expect(checks).to be >= 2
    expect(MarketplaceFunnelEvent.exists?(old.id)).to be(true)
  end
end
