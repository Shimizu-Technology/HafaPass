# frozen_string_literal: true

module Operations
  # Read-only health of the Stripe webhook path, derived from the receipts and
  # payments the app already stores (no new table). OperationalAlertJob turns
  # the two signals below into Sentry alerts.
  #
  #   stripe_webhook_failures  Receipts that failed (or hung in "processing")
  #                            recently, once there are at least FAILURE_THRESHOLD.
  #   stripe_webhooks_silent   No Stripe receipt for SILENCE_MINUTES *while the
  #                            database shows webhooks should have arrived*:
  #                            (a) a Stripe payment is marked succeeded but its
  #                            payment_intent.succeeded webhook never arrived, or
  #                            (b) at least MIN_ATTEMPTS payments were started in
  #                            the silent window and not one webhook of any kind
  #                            came in. An hour with no buyers is never silence.
  #
  # Thresholds come from the environment so Leon can tune them on Render
  # without a deploy; invalid values fall back to the default.
  class StripeWebhookHealth
    SIGNALS = %w[stripe_webhook_failures stripe_webhooks_silent].freeze
    PROVIDER = "stripe"
    SUCCESS_EVENT = "payment_intent.succeeded"
    STUCK_PROCESSING_AFTER = 10.minutes

    DEFAULTS = {
      "HAFAPASS_WEBHOOK_FAILURE_WINDOW_MINUTES" => 15,
      "HAFAPASS_WEBHOOK_FAILURE_THRESHOLD" => 3,
      "HAFAPASS_WEBHOOK_SILENCE_MINUTES" => 30,
      "HAFAPASS_WEBHOOK_SILENCE_LOOKBACK_MINUTES" => 360,
      "HAFAPASS_WEBHOOK_SILENCE_MIN_ATTEMPTS" => 10
    }.freeze

    def self.call(now: Time.current)
      new(now: now).call
    end

    def self.env_integer(key)
      value = Integer(ENV[key].to_s.strip, 10, exception: false)
      value&.positive? ? value : DEFAULTS.fetch(key)
    end

    def initialize(now: Time.current)
      @now = now
    end

    # Counts per alert signal (0 means healthy).
    def signals
      { "stripe_webhook_failures" => failure_count, "stripe_webhooks_silent" => silent_count }
    end

    # Non-secret context attached to the Sentry event for a signal.
    def details(signal)
      case signal
      when "stripe_webhook_failures"
        { window_minutes: failure_window.in_minutes.to_i, threshold: failure_threshold, stuck_processing: stuck_processing_count }
      when "stripe_webhooks_silent"
        { silence_minutes: silence.in_minutes.to_i, paid_without_webhook: paid_without_webhook_count,
          recent_payment_attempts: recent_attempt_count, min_attempts: min_attempts,
          last_receipt_at: last_receipt_at&.iso8601 }
      else
        {}
      end
    end

    def call
      {
        checked_at: now.iso8601,
        last_receipt_at: last_receipt_at&.iso8601,
        last_processed_at: last_processed_at&.iso8601,
        receipts_last_hour: receipts.where(created_at: (now - 1.hour)..).count,
        failed_in_window: recent_failed_count,
        stuck_processing: stuck_processing_count,
        failed_total: receipts.failed.count,
        paid_without_webhook: paid_without_webhook_count,
        recent_payment_attempts: recent_attempt_count,
        silent: silent_count.positive?,
        failing: failure_count.positive?,
        thresholds: {
          failure_window_minutes: failure_window.in_minutes.to_i, failure_threshold: failure_threshold,
          silence_minutes: silence.in_minutes.to_i, silence_lookback_minutes: lookback.in_minutes.to_i,
          silence_min_attempts: min_attempts
        }
      }
    end

    private

    attr_reader :now

    def failure_window = self.class.env_integer("HAFAPASS_WEBHOOK_FAILURE_WINDOW_MINUTES").minutes
    def failure_threshold = self.class.env_integer("HAFAPASS_WEBHOOK_FAILURE_THRESHOLD")
    def silence = self.class.env_integer("HAFAPASS_WEBHOOK_SILENCE_MINUTES").minutes
    def lookback = [self.class.env_integer("HAFAPASS_WEBHOOK_SILENCE_LOOKBACK_MINUTES").minutes, silence].max
    def min_attempts = self.class.env_integer("HAFAPASS_WEBHOOK_SILENCE_MIN_ATTEMPTS")

    def receipts
      @receipts ||= WebhookEvent.where(provider: PROVIDER)
    end

    def last_receipt_at
      return @last_receipt_at if defined?(@last_receipt_at)

      @last_receipt_at = receipts.maximum(:created_at)
    end

    def last_processed_at
      receipts.processed.maximum(:processed_at)
    end

    def recent_failed_count
      @recent_failed_count ||= receipts.failed.where(updated_at: (now - failure_window)..).count
    end

    def stuck_processing_count
      @stuck_processing_count ||= receipts.processing.where(updated_at: ...(now - STUCK_PROCESSING_AFTER)).count
    end

    def failure_count
      total = recent_failed_count + stuck_processing_count
      total >= failure_threshold ? total : 0
    end

    def webhooks_arriving?
      last_receipt_at.present? && last_receipt_at > now - silence
    end

    # Evidence (a): paid per our records, but no matching success webhook. The
    # grace period (silence) lets a normal late webhook or the buyer-return
    # recovery path settle first.
    def paid_without_webhook_count
      @paid_without_webhook_count ||= Payment.where(provider: PROVIDER, provider_environment: %w[test live])
        .where(status: [:succeeded, :partially_refunded, :refunded])
        .where(succeeded_at: (now - lookback)..(now - silence))
        .where.not(id: PaymentEvent.where(event_type: SUCCESS_EVENT).where.not(payment_id: nil).select(:payment_id))
        .count
    end

    # Evidence (b): enough payment attempts in the silent window that at least
    # one webhook of some kind should have come in.
    def recent_attempt_count
      @recent_attempt_count ||= Payment.where(provider: PROVIDER, provider_environment: %w[test live])
        .where(created_at: (now - silence)..).count
    end

    def silent_count
      return 0 if webhooks_arriving?

      evidence = paid_without_webhook_count
      evidence += recent_attempt_count if recent_attempt_count >= min_attempts
      evidence
    end
  end
end
