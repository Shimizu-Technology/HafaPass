# frozen_string_literal: true

require "rails_helper"

RSpec.describe Operations::StripeWebhookHealth do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| freeze_time { example.run } }

  let(:now) { Time.current }

  def receipt(status: :processed, at: now, event_type: "payment_intent.succeeded", updated_at: at, livemode: false)
    WebhookEvent.create!(provider: "stripe", provider_event_id: "evt_#{SecureRandom.hex(6)}", event_type: event_type,
      status: status, created_at: at, updated_at: updated_at, processed_at: (status == :processed ? at : nil),
      payload: { "livemode" => livemode })
  end

  def paid_payment(succeeded_at:, confirmed: false, environment: "test", provider: "stripe")
    payment = create(:payment, status: :succeeded, succeeded_at: succeeded_at, provider_environment: environment, provider: provider)
    PaymentEvent.create!(payment: payment, webhook_event: receipt(at: succeeded_at), event_type: described_class::SUCCESS_EVENT) if confirmed
    payment
  end

  def attempts(count, at: now - 5.minutes, environment: "test")
    count.times { create(:payment, created_at: at, provider_environment: environment) }
  end

  def signals(mode: "test") = described_class.new(mode: mode).signals

  it "is healthy when there is nothing to report" do
    expect(signals).to eq("stripe_webhook_failures" => 0, "stripe_webhook_signature_failures" => 0, "stripe_webhooks_silent" => 0)
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
      expect(described_class.new(now: three_am).signals.values).to all(eq(0))
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

    it "stays quiet about attempts while any webhook is arriving, even with many attempts" do
      attempts(25)
      receipt(at: now - 5.minutes, event_type: "charge.updated")
      expect(signals["stripe_webhooks_silent"]).to eq(0)
    end

    it "still fires for a paid payment with no success webhook while unrelated webhooks keep arriving" do
      paid_payment(succeeded_at: now - 45.minutes)
      receipt(at: now - 1.minute, event_type: "charge.updated")
      expect(signals["stripe_webhooks_silent"]).to eq(1)
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

    it "clears when the missing success webhook is finally delivered, not merely when other webhooks arrive" do
      payment = paid_payment(succeeded_at: now - 45.minutes)
      expect(signals["stripe_webhooks_silent"]).to eq(1)
      PaymentEvent.create!(payment: payment, webhook_event: receipt(at: now - 1.minute), event_type: described_class::SUCCESS_EVENT)
      expect(signals["stripe_webhooks_silent"]).to eq(0)
    end

    it "clears the attempts evidence as soon as any webhook resumes" do
      attempts(12)
      expect(signals["stripe_webhooks_silent"]).to eq(12)
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

  describe "Stripe mode" do
    it "judges live traffic only in live mode: test receipts and payments can't mask or cause a live incident" do
      attempts(12, environment: "live")
      receipt(at: now - 1.minute, livemode: false)
      expect(signals(mode: "live")["stripe_webhooks_silent"]).to eq(12)
      receipt(at: now - 1.minute, livemode: true)
      expect(signals(mode: "live")["stripe_webhooks_silent"]).to eq(0)
    end

    it "ignores live payments and receipts in test mode" do
      attempts(12, environment: "live")
      paid_payment(succeeded_at: now - 45.minutes, environment: "live")
      3.times { receipt(status: :failed, at: now - 1.minute, livemode: true) }
      expect(signals(mode: "test").values).to all(eq(0))
    end

    it "counts only live failures in live mode" do
      3.times { receipt(status: :failed, at: now - 1.minute, livemode: false) }
      expect(signals(mode: "live")["stripe_webhook_failures"]).to eq(0)
      3.times { receipt(status: :failed, at: now - 1.minute, livemode: true) }
      expect(signals(mode: "live")["stripe_webhook_failures"]).to eq(3)
    end

    it "uses live in production and test elsewhere" do
      expect(described_class.default_mode).to eq("test")
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))
      expect(described_class.default_mode).to eq("live")
    end
  end

  describe "signature failures" do
    def reject!(reason, times, at: now - 2.minutes)
      times.times { Operations::WebhookRejections.record!(provider: "stripe", reason: reason, at: at) }
    end

    it "fires at the threshold for a wrong secret or a missing one, though no receipt exists" do
      reject!("invalid_signature", 2)
      expect(signals["stripe_webhook_signature_failures"]).to eq(0)
      reject!("secret_missing", 1)
      expect(signals["stripe_webhook_signature_failures"]).to eq(3)
      expect(WebhookEvent.count).to eq(0)
    end

    it "ignores unsigned internet noise and old rejections" do
      reject!("signature_missing", 500)
      reject!("invalid_signature", 50, at: now - 2.hours)
      expect(signals["stripe_webhook_signature_failures"]).to eq(0)
    end

    it "reads its threshold from the environment" do
      reject!("invalid_signature", 1)
      with_env("HAFAPASS_WEBHOOK_SIGNATURE_FAILURE_THRESHOLD" => "1") { expect(signals["stripe_webhook_signature_failures"]).to eq(1) }
    end
  end

  describe "recovery evidence" do
    it "is affirmative only when a webhook was processed after the incident opened" do
      health = described_class.new
      opened = now - 30.minutes
      expect(health.affirmative_recovery?("stripe_webhooks_silent", since: opened)).to be(false)
      receipt(status: :failed, at: now - 5.minutes)
      expect(health.affirmative_recovery?("stripe_webhook_failures", since: opened)).to be(false)
      receipt(at: now - 40.minutes)
      expect(health.affirmative_recovery?("stripe_webhook_failures", since: opened)).to be(false)
      receipt(at: now - 1.minute)
      expect(health.affirmative_recovery?("stripe_webhook_failures", since: opened)).to be(true)
      expect(health.affirmative_recovery?("stripe_webhooks_silent", since: opened)).to be(true)
    end

    it "treats a verified receipt arriving after the incident as proof the signing secret works" do
      health = described_class.new
      expect(health.affirmative_recovery?("stripe_webhook_signature_failures", since: now - 10.minutes)).to be(false)
      receipt(status: :failed, at: now - 1.minute)
      expect(health.affirmative_recovery?("stripe_webhook_signature_failures", since: now - 10.minutes)).to be(true)
    end

    it "counts the rows that still need a person" do
      receipt(status: :failed, at: now - 3.hours)
      paid_payment(succeeded_at: now - 2.days)
      health = described_class.new
      expect(health.unresolved_count("stripe_webhook_failures")).to eq(1)
      expect(health.unresolved_count("stripe_webhooks_silent")).to eq(1)
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
