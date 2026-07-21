require "rails_helper"

RSpec.describe Operations::CommerceClock do
  include ActiveJob::TestHelper

  it "enqueues hold expiry every tick and marketplace retention once per UTC date" do
    clock = described_class.new
    first_tick = Time.utc(2026, 7, 21, 1)

    clock.tick(at: first_tick)
    expect(enqueued_jobs.count { |job| job[:job] == ExpireInventoryHoldsJob }).to eq(1)
    expect(enqueued_jobs.count { |job| job[:job] == ExpireSeatHoldsJob }).to eq(1)
    expect(enqueued_jobs.count { |job| job[:job] == PurgeMarketplaceAnalyticsJob }).to eq(1)
    clear_enqueued_jobs

    clock.tick(at: first_tick + 1.hour)
    expect(enqueued_jobs.count { |job| job[:job] == ExpireInventoryHoldsJob }).to eq(1)
    expect(enqueued_jobs.count { |job| job[:job] == ExpireSeatHoldsJob }).to eq(1)
    expect(enqueued_jobs.none? { |job| job[:job] == PurgeMarketplaceAnalyticsJob }).to be(true)
    clear_enqueued_jobs

    clock.tick(at: first_tick + 1.day)
    expect(enqueued_jobs.count { |job| job[:job] == PurgeMarketplaceAnalyticsJob }).to eq(1)
  end
end
