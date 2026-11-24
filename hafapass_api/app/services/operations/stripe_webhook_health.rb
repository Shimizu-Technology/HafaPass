# frozen_string_literal: true

module Operations
  # Read-only health of the Stripe webhook path, derived from the receipts and
  # payments the app already stores plus a counter of rejected deliveries.
  # OperationalAlertJob turns the signals below into Sentry alerts.
  #
  #   stripe_webhook_failures            Receipts that failed (or hung in
  #                                      "processing") recently, once there are
  #                                      at least FAILURE_THRESHOLD.
  #   stripe_webhook_signature_failures  Deliveries Stripe sent that failed
  #                                      signature verification (a wrong or
  #                                      rotated signing secret) or arrived with
  #                                      no secret configured. No receipt is
  #                                      stored for these, so they are counted.
  #   stripe_webhooks_silent             (a) A Stripe payment is marked paid but
  #                                      its payment_intent.succeeded webhook
  #                                      never arrived (judged on its own, other
  #                                      webhooks arriving doesn't hide it), or
  #                                      (b) at least MIN_ATTEMPTS payments were
  #                                      started in the silent window and no
  #                                      webhook at all came in. An hour with no
  #                                      buyers is never silence.
  #
  # Everything is scoped to one Stripe mode: live in production, test
  # elsewhere, matching the livemode flag Stripe signs into each event and the
  # payment's provider_environment. Test-mode traffic can't mask or cause a
  # live incident.
  #
  # Thresholds come from the environment so Leon can tune them on Render
  # without a deploy; invalid values fall back to the default.
  class StripeWebhookHealth
    SIGNALS = %w[stripe_webhook_failures stripe_webhook_signature_failures stripe_webhooks_silent].freeze
    PROVIDER = "stripe"
    SUCCESS_EVENT = "payment_intent.succeeded"
    STUCK_PROCESSING_AFTER = 10.minutes
    UNRESOLVED_LOOKBACK = 7.days

    DEFAULTS = {
      "HAFAPASS_WEBHOOK_FAILURE_WINDOW_MINUTES" => 15,
      "HAFAPASS_WEBHOOK_FAILURE_THRESHOLD" => 3,
      "HAFAPASS_WEBHOOK_SIGNATURE_FAILURE_THRESHOLD" => 3,
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

    def self.default_mode = Rails.env.production? ? "live" : "test"

    def initialize(now: Time.current, mode: self.class.default_mode)
      @now = now
      @mode = mode
    end

    # Counts per signal (0 means healthy). One broken signal never hides the
    # others: callers that need isolation use #signal.
    def signals
      SIGNALS.index_with { |signal| signal(signal) }
    end

    def signal(name)
      case name
      when "stripe_webhook_failures" then failure_count
      when "stripe_webhook_signature_failures" then signature_failure_count
      when "stripe_webhooks_silent" then silent_count
      else raise ArgumentError, "Unknown webhook signal"
      end
    end

    # Non-secret context attached to the Sentry event for a signal.
    def details(name)
      case name
      when "stripe_webhook_failures"
        { mode: mode, window_minutes: failure_window.in_minutes.to_i, threshold: failure_threshold, stuck_processing: stuck_processing_count }
      when "stripe_webhook_signature_failures"
        { window_minutes: failure_window.in_minutes.to_i, threshold: signature_threshold, rejected_in_window: rejected_in_window }
      when "stripe_webhooks_silent"
        { mode: mode, silence_minutes: silence.in_minutes.to_i, paid_without_webhook: paid_without_webhook_count,
          recent_payment_attempts: recent_attempt_count, min_attempts: min_attempts, last_receipt_at: last_receipt_at&.iso8601 }
      else
        {}
      end
    end

    # True when the signal's evidence ended because something worked after the
    # incident opened, as opposed to simply aging out of the window.
    def affirmative_recovery?(name, since:)
      case name
      when "stripe_webhook_failures", "stripe_webhooks_silent"
        receipts.processed.where(processed_at: (since + 1.second)..).exists?
      when "stripe_webhook_signature_failures"
        receipts.where(created_at: (since + 1.second)..).exists?
      else
        false
      end
    end

    # Rows that still need a person even though the signal went quiet.
    def unresolved_count(name)
      case name
      when "stripe_webhook_failures" then receipts.failed.count
      when "stripe_webhooks_silent" then unconfirmed_paid(now - UNRESOLVED_LOOKBACK, now - silence).count
      else 0
      end
    end

    def call
      {
        checked_at: now.iso8601,
        mode: mode,
        last_receipt_at: last_receipt_at&.iso8601,
        last_processed_at: last_processed_at&.iso8601,
        receipts_last_hour: receipts.where(created_at: (now - 1.hour)..).count,
        failed_in_window: recent_failed_count,
        stuck_processing: stuck_processing_count,
        failed_total: receipts.failed.count,
        rejected_in_window: rejected_in_window,
        paid_without_webhook: paid_without_webhook_count,
        recent_payment_attempts: recent_attempt_count,
        silent: silent_count.positive?,
        failing: failure_count.positive?,
        signature_failing: signature_failure_count.positive?,
        thresholds: {
          failure_window_minutes: failure_window.in_minutes.to_i, failure_threshold: failure_threshold,
          signature_failure_threshold: signature_threshold,
          silence_minutes: silence.in_minutes.to_i, silence_lookback_minutes: lookback.in_minutes.to_i,
          silence_min_attempts: min_attempts
        }
      }
    end

    private

    attr_reader :now, :mode

    def failure_window = self.class.env_integer("HAFAPASS_WEBHOOK_FAILURE_WINDOW_MINUTES").minutes
    def failure_threshold = self.class.env_integer("HAFAPASS_WEBHOOK_FAILURE_THRESHOLD")
    def signature_threshold = self.class.env_integer("HAFAPASS_WEBHOOK_SIGNATURE_FAILURE_THRESHOLD")
    def silence = self.class.env_integer("HAFAPASS_WEBHOOK_SILENCE_MINUTES").minutes
    def lookback = [self.class.env_integer("HAFAPASS_WEBHOOK_SILENCE_LOOKBACK_MINUTES").minutes, silence].max
    def min_attempts = self.class.env_integer("HAFAPASS_WEBHOOK_SILENCE_MIN_ATTEMPTS")

    # Receipts of this Stripe mode. Stripe signs livemode into every event; a
    # receipt without the flag (old local fixtures) counts as test.
    def receipts
      scope = WebhookEvent.where(provider: PROVIDER)
      mode == "live" ? scope.where("webhook_events.payload->>'livemode' = 'true'")
        : scope.where("webhook_events.payload->>'livemode' IS DISTINCT FROM 'true'")
    end

    def stripe_payments
      Payment.where(provider: PROVIDER, provider_environment: mode)
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

    def rejected_in_window
      @rejected_in_window ||= Operations::WebhookRejections.count(provider: PROVIDER, since: now - failure_window)
    end

    def signature_failure_count
      rejected_in_window >= signature_threshold ? rejected_in_window : 0
    end

    def webhooks_arriving?
      last_receipt_at.present? && last_receipt_at > now - silence
    end

    def unconfirmed_paid(from, to)
      stripe_payments.where(status: [:succeeded, :partially_refunded, :refunded], succeeded_at: from..to)
        .where.not(id: PaymentEvent.where(event_type: SUCCESS_EVENT).where.not(payment_id: nil).select(:payment_id))
    end

    # Evidence (a): paid per our records, but no matching success webhook. The
    # grace period (silence) lets a normal late webhook or the buyer-return
    # recovery path settle first. Judged on its own: other webhooks arriving
    # does not excuse a payment whose success event never came.
    def paid_without_webhook_count
      @paid_without_webhook_count ||= unconfirmed_paid(now - lookback, now - silence).count
    end

    # Evidence (b): enough payment attempts in the silent window that at least
    # one webhook of some kind should have come in.
    def recent_attempt_count
      @recent_attempt_count ||= stripe_payments.where(created_at: (now - silence)..).count
    end

    def silent_count
      evidence = paid_without_webhook_count
      evidence += recent_attempt_count if !webhooks_arriving? && recent_attempt_count >= min_attempts
      evidence
    end
  end
end
