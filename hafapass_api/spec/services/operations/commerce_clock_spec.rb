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

  it "sweeps persisted Stripe fee evidence immediately and at most once per five-minute interval" do
    clock = described_class.new
    first_tick = Time.utc(2026, 10, 10, 1)

    clock.tick(at: first_tick)
    expect(enqueued_jobs.count { |job| job[:job] == SweepPendingStripeFeesJob }).to eq(1)
    clear_enqueued_jobs

    4.times { |index| clock.tick(at: first_tick + (index + 1).minutes) }
    expect(enqueued_jobs.none? { |job| job[:job] == SweepPendingStripeFeesJob }).to be(true)
    expect(enqueued_jobs.count { |job| job[:job] == ExpireInventoryHoldsJob }).to eq(4)

    clock.tick(at: first_tick + 5.minutes)
    expect(enqueued_jobs.count { |job| job[:job] == SweepPendingStripeFeesJob }).to eq(1)
    clock.tick(at: first_tick + 5.minutes)
    expect(enqueued_jobs.count { |job| job[:job] == SweepPendingStripeFeesJob }).to eq(1)
  end

  it "recovers due work after a delayed tick or clock restart without replaying every missed interval" do
    first_tick = Time.utc(2026, 10, 10, 1)
    clock = described_class.new
    clock.tick(at: first_tick)
    clear_enqueued_jobs

    clock.tick(at: first_tick + 1.hour)
    expect(enqueued_jobs.count { |job| job[:job] == SweepPendingStripeFeesJob }).to eq(1)
    clear_enqueued_jobs
    described_class.new.tick(at: first_tick + 1.hour + 1.minute)
    expect(enqueued_jobs.count { |job| job[:job] == SweepPendingStripeFeesJob }).to eq(1)
  end

  it "retries on the next tick when queueing the sweep failed" do
    first_tick = Time.utc(2026, 10, 10, 1)
    clock = described_class.new
    allow(SweepPendingStripeFeesJob).to receive(:perform_later).and_raise(IOError, "queue unavailable")
    expect { clock.tick(at: first_tick) }.to raise_error(IOError, "queue unavailable")

    allow(SweepPendingStripeFeesJob).to receive(:perform_later).and_call_original
    expect { clock.tick(at: first_tick + 1.minute) }.to have_enqueued_job(SweepPendingStripeFeesJob)
  end
end
