# frozen_string_literal: true

require "rails_helper"

RSpec.describe Operations::StripeWebhookHealth do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| freeze_time { example.run } }

  let(:now) { Time.current }

  def receipt(status: :processed, at: now, event_type: "payment_intent.succeeded", updated_at: at)
    WebhookEvent.create!(provider: "stripe", provider_event_id: "evt_#{SecureRandom.hex(6)}", event_type: event_type,
      status: status, created_at: at, updated_at: updated_at, processed_at: (status == :processed ? at : nil))
  end

  def paid_payment(succeeded_at:, confirmed: false, environment: "test", provider: "stripe")
    payment = create(:payment, status: :succeeded, succeeded_at: succeeded_at, provider_environment: environment, provider: provider)
    PaymentEvent.create!(payment: payment, webhook_event: receipt(at: succeeded_at), event_type: described_class::SUCCESS_EVENT) if confirmed
    payment
  end

  def attempts(count, at: now - 5.minutes)
    count.times { create(:payment, created_at: at) }
  end

  def signals = described_class.new.signals

  it "is healthy when there is nothing to report" do
    expect(signals).to eq("stripe_webhook_failures" => 0, "stripe_webhooks_silent" => 0)
  end

  describe "failures" do
    it "fires at the threshold of recent failed receipts and counts hung ones" do
      2.times { receipt(status: :failed, at: now - 2.minutes) }
      expect(signals["stripe_webhook_failures"]).to eq(0)

      receipt(status: :processing, at: now - 20.minutes, updated_at: now - 11.minutes)
      expect(signals["stripe_webhook_failures"]).to eq(3)
    end

    it "ignores old failures, in-flight processing and other providers" do
      5.times { receipt(status: :failed, at: now - 2.hours) }
      5.times { receipt(status: :processing, at: now - 1.minute) }
      WebhookEvent.create!(provider: "resend", provider_event_id: "evt_r", event_type: "x", status: :failed)
      expect(signals["stripe_webhook_failures"]).to eq(0)
    end

    it "reads thresholds from the environment and ignores bad values" do
      2.times { receipt(status: :failed, at: now - 1.minute) }
      with_env("HAFAPASS_WEBHOOK_FAILURE_THRESHOLD" => "2") { expect(signals["stripe_webhook_failures"]).to eq(2) }
      with_env("HAFAPASS_WEBHOOK_FAILURE_THRESHOLD" => "nonsense") { expect(signals["stripe_webhook_failures"]).to eq(0) }
      with_env("HAFAPASS_WEBHOOK_FAILURE_THRESHOLD" => "0") { expect(signals["stripe_webhook_failures"]).to eq(0) }
    end
  end

  describe "silence" do
    it "never fires because nobody is buying (no payments, no receipts, at any hour)" do
      three_am = Time.find_zone!("Pacific/Guam").local(2027, 1, 5, 3, 0)
      expect(described_class.new(now: three_am).signals).to eq("stripe_webhook_failures" => 0, "stripe_webhooks_silent" => 0)
    end

    it "does not fire for a few abandoned checkouts" do
      attempts(9)
      expect(signals["stripe_webhooks_silent"]).to eq(0)
    end

    it "does not fire for abandoned old checkouts" do
      attempts(40, at: now - 3.hours)
      expect(signals["stripe_webhooks_silent"]).to eq(0)
    end

    it "fires when payments were started and not a single webhook came in" do
      attempts(10)
      expect(signals["stripe_webhooks_silent"]).to eq(10)
    end

    it "stays quiet while any webhook is arriving, even with many attempts" do
      attempts(25)
      receipt(at: now - 5.minutes, event_type: "charge.updated")
      expect(signals["stripe_webhooks_silent"]).to eq(0)
    end

    it "fires when a payment is marked paid but its success webhook never arrived" do
      paid_payment(succeeded_at: now - 45.minutes)
      expect(signals["stripe_webhooks_silent"]).to eq(1)
    end

    it "gives a fresh payment a grace period" do
      paid_payment(succeeded_at: now - 10.minutes)
      expect(signals["stripe_webhooks_silent"]).to eq(0)
    end

    it "ignores confirmed payments, other providers, simulated payments and payments past the lookback" do
      paid_payment(succeeded_at: now - 45.minutes, confirmed: true)
      paid_payment(succeeded_at: now - 45.minutes, provider: "door_cash")
      paid_payment(succeeded_at: now - 45.minutes, environment: "simulate")
      paid_payment(succeeded_at: now - 7.hours)
      expect(signals["stripe_webhooks_silent"]).to eq(0)
    end

    it "clears as soon as webhooks resume" do
      paid_payment(succeeded_at: now - 45.minutes)
      expect(signals["stripe_webhooks_silent"]).to eq(1)
      receipt(at: now - 1.minute)
      expect(signals["stripe_webhooks_silent"]).to eq(0)
    end

    it "uses the configured silence window and attempt minimum" do
      attempts(3, at: now - 5.minutes)
      with_env("HAFAPASS_WEBHOOK_SILENCE_MIN_ATTEMPTS" => "3") { expect(signals["stripe_webhooks_silent"]).to eq(3) }
      receipt(at: now - 20.minutes)
      with_env("HAFAPASS_WEBHOOK_SILENCE_MIN_ATTEMPTS" => "3") { expect(signals["stripe_webhooks_silent"]).to eq(0) }
      with_env("HAFAPASS_WEBHOOK_SILENCE_MIN_ATTEMPTS" => "3", "HAFAPASS_WEBHOOK_SILENCE_MINUTES" => "10") do
        expect(signals["stripe_webhooks_silent"]).to eq(3)
      end
    end
  end

  it "reports the last receipt and processing time without secrets or payloads" do
    receipt(at: now - 3.minutes)
    snapshot = described_class.call
    expect(snapshot).to include(last_receipt_at: (now - 3.minutes).iso8601, last_processed_at: (now - 3.minutes).iso8601,
      receipts_last_hour: 1, silent: false, failing: false)
    expect(snapshot.to_json).not_to match(/evt_|payload/)
  end

  def with_env(overrides)
    originals = overrides.keys.index_with { |key| ENV[key] }
    overrides.each { |key, value| ENV[key] = value }
    yield
  ensure
    originals.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
