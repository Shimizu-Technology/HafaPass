# frozen_string_literal: true

require "rails_helper"

RSpec.describe Operations::WebhookRejections do
  include ActiveSupport::Testing::TimeHelpers

  let(:clock) { { now: 1000.0 } }

  before { allow(described_class).to receive(:monotonic_now) { clock[:now] } }

  def record(times = 1, reason: "invalid_signature", at: Time.current)
    times.times { described_class.record!(provider: "stripe", reason: reason, at: at) }
  end

  it "writes at most once per interval however many rejections arrive" do
    allow(WebhookRejectionCount).to receive(:upsert_all).and_call_original

    record(1000)

    expect(WebhookRejectionCount).to have_received(:upsert_all).once
    expect(described_class.pending_count).to eq(999)
    expect(WebhookRejectionCount.sum(:count)).to eq(1)
  end

  it "flushes the buffered counts as one statement after the interval, adding to the bucket" do
    allow(WebhookRejectionCount).to receive(:upsert_all).and_call_original
    record(500)
    clock[:now] += 11
    record(1)

    expect(WebhookRejectionCount).to have_received(:upsert_all).twice
    expect(WebhookRejectionCount.sum(:count)).to eq(501)
    expect(WebhookRejectionCount.count).to eq(1)
    expect(described_class.pending_count).to eq(0)
  end

  it "schedules one trailing flush for a burst, so counts don't wait for the next rejection" do
    allow(described_class).to receive(:schedule_trailing_flush)
    record(50)
    expect(described_class).to have_received(:schedule_trailing_flush).once.with(be_within(0.1).of(10))
  end

  it "counts what it holds when read, so the alert job sees this process's pending rejections" do
    record(7)
    expect(described_class.pending_count).to eq(6)
    expect(described_class.count(provider: "stripe", since: 1.hour.ago)).to eq(7)
    expect(described_class.pending_count).to eq(0)
  end

  it "bounds memory: distinct buckets beyond the cap are dropped, not accumulated" do
    stub_const("#{described_class}::MAX_PENDING_KEYS", 5)
    allow(WebhookRejectionCount).to receive(:upsert_all)
    record(1)                                       # first write flushes
    20.times { |n| record(1, at: Time.current + (n * 10).minutes) }
    expect(described_class.pending_count).to eq(5)
  end

  it "keeps the counts when the database write fails, and never raises" do
    allow(WebhookRejectionCount).to receive(:upsert_all).and_raise(ActiveRecord::StatementInvalid, "down")
    expect { record(3) }.not_to raise_error
    expect(described_class.pending_count).to eq(3)
    allow(WebhookRejectionCount).to receive(:upsert_all).and_call_original
    described_class.flush!
    expect(WebhookRejectionCount.sum(:count)).to eq(3)
  end

  it "ignores unknown reasons and can be set to write through" do
    record(1, reason: "who_knows")
    expect(WebhookRejectionCount.count).to eq(0)
    original = ENV["HAFAPASS_WEBHOOK_REJECTION_FLUSH_SECONDS"]
    ENV["HAFAPASS_WEBHOOK_REJECTION_FLUSH_SECONDS"] = "0"
    record(4)
    expect(WebhookRejectionCount.sum(:count)).to eq(4)
  ensure
    original.nil? ? ENV.delete("HAFAPASS_WEBHOOK_REJECTION_FLUSH_SECONDS") : ENV["HAFAPASS_WEBHOOK_REJECTION_FLUSH_SECONDS"] = original
  end

  describe "inside a read-only block (the ops summary)" do
    it "reads without writing, counts the pending rejections too, and leaves the flush clock alone" do
      record(5)                                          # 1 written at once, 4 pending
      expect(WebhookRejectionCount.sum(:count)).to eq(1)
      expect(described_class.pending_count).to eq(4)
      clock_before = described_class.instance_variable_get(:@last_flush)
      allow(WebhookRejectionCount).to receive(:upsert_all).and_call_original

      total = ActiveRecord::Base.while_preventing_writes do
        described_class.count(provider: "stripe", since: 1.hour.ago)
      end

      expect(total).to eq(5)                              # not 1: pending counts are included
      expect(WebhookRejectionCount).not_to have_received(:upsert_all)
      expect(described_class.pending_count).to eq(4)      # nothing re-queued, nothing lost
      expect(described_class.instance_variable_get(:@last_flush)).to eq(clock_before)

      described_class.flush!                              # outside the block it writes the rest
      expect(WebhookRejectionCount.sum(:count)).to eq(5)
      expect(described_class.count(provider: "stripe", since: 1.hour.ago)).to eq(5)
    end

    it "logs no flush failure and raises nothing" do
      record(3)
      allow(Rails.logger).to receive(:error)
      expect { ActiveRecord::Base.while_preventing_writes { described_class.flush! } }.not_to raise_error
      expect(Rails.logger).not_to have_received(:error).with(/webhook_rejection_flush_failed/)
    end
  end

  it "advances the flush clock only when a write succeeds" do
    record(1)                                           # first write at t=1000
    clock[:now] += 20
    allow(WebhookRejectionCount).to receive(:upsert_all).and_raise(ActiveRecord::StatementInvalid, "down")
    described_class.flush!
    expect(described_class.instance_variable_get(:@last_flush)).to eq(1000.0)
    allow(WebhookRejectionCount).to receive(:upsert_all).and_call_original
    record(1)                                           # due again, writes both
    expect(WebhookRejectionCount.sum(:count)).to eq(2)
  end

  it "claims the flush slot inside the lock, so two concurrent first rejections write once" do
    allow(WebhookRejectionCount).to receive(:upsert_all).and_call_original
    threads = Array.new(8) { Thread.new { record(5) } }
    threads.each(&:join)
    expect(WebhookRejectionCount).to have_received(:upsert_all).once
    described_class.flush!
    expect(WebhookRejectionCount.sum(:count)).to eq(40)
  end

  it "recognizes only Stripe-shaped signature headers" do
    expect(described_class.stripe_shaped?("t=1700000000,v1=#{'a' * 64}")).to be(true)
    ["garbage", "t=1,v1=bad", "", nil, "v1=#{'a' * 64}"].each { |bad| expect(described_class.stripe_shaped?(bad)).to be(false) }
  end
end
