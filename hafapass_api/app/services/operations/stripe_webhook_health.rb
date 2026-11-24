# frozen_string_literal: true

module Operations
  # Read-only health of the Stripe webhook path, derived from the receipts and
  # payments the app already stores plus a counter of rejected deliveries.
  # OperationalAlertJob turns the signals below into Sentry alerts.
  #
  #   stripe_webhook_failures            Receipts that failed (or hung in
  #                                      "processing") recently, once there are
  #                                      at least FAILURE_THRESHOLD.
  #   stripe_unverified_deliveries       Deliveries rejected for a bad signature
  #                                      (or no secret configured). They prove
  #                                      nothing on their own: unverified senders
  #                                      can't establish a Stripe mode or origin,
  #                                      and the URL is public. So this pages only
  #                                      when the rejections coincide with
  #                                      evidence real deliveries are missing (no
  #                                      verified receipt for N minutes while
  #                                      payments were started or paid); otherwise
  #                                      the job records an info-level note.
  #   stripe_webhooks_silent             (a) A Stripe payment is marked paid but
  #                                      its payment_intent.succeeded webhook
  #                                      never arrived (judged on its own, other
  #                                      webhooks arriving doesn't hide it), or
  #                                      (b) at least MIN_ATTEMPTS payments were
  #                                      started in the silent window and no
  #                                      webhook at all came in. An hour with no
  #                                      buyers is never silence.
  #
  # Receipts and payments are scoped to one Stripe mode: live in production,
  # test elsewhere, matching the livemode flag Stripe signs into each event and
  # the payment's provider_environment. Test-mode traffic can't mask or cause a
  # live incident. (Rejected deliveries can't be scoped: see above.)
  #
  # Thresholds come from the environment so Leon can tune them on Render
  # without a deploy; invalid values fall back to the default.
  class StripeWebhookHealth
    SIGNALS = %w[stripe_webhook_failures stripe_unverified_deliveries stripe_webhooks_silent].freeze
    NOTE_SIGNAL = "stripe_unverified_deliveries_note"
    PROVIDER = "stripe"
    SUCCESS_EVENT = "payment_intent.succeeded"
    STUCK_PROCESSING_AFTER = 10.minutes
    UNRESOLVED_LOOKBACK = 7.days

    DEFAULTS = {
      "HAFAPASS_WEBHOOK_FAILURE_WINDOW_MINUTES" => 15,
      "HAFAPASS_WEBHOOK_FAILURE_THRESHOLD" => 3,
      "HAFAPASS_WEBHOOK_UNVERIFIED_THRESHOLD" => 3,
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
      when "stripe_unverified_deliveries" then unverified_alert_count
      when NOTE_SIGNAL then unverified_note_count
      when "stripe_webhooks_silent" then silent_count
      else raise ArgumentError, "Unknown webhook signal"
      end
    end

    # Non-secret context attached to the Sentry event for a signal.
    def details(name)
      case name
      when "stripe_webhook_failures"
        { mode: mode, window_minutes: failure_window.in_minutes.to_i, threshold: failure_threshold, stuck_processing: stuck_processing_count }
      when "stripe_unverified_deliveries"
        { window_minutes: failure_window.in_minutes.to_i, threshold: unverified_threshold, rejected_in_window: rejected_in_window,
          note: "Unverified rejected deliveries; no verified receipt for #{silence.in_minutes.to_i} minutes while payments were started or paid." }
      when NOTE_SIGNAL
        { window_minutes: failure_window.in_minutes.to_i, threshold: unverified_threshold, rejected_in_window: rejected_in_window,
          note: "Unverified rejected deliveries with no sign real deliveries are missing (verified receipts are arriving, or no payments were made)." }
      when "stripe_webhooks_silent"
        { mode: mode, silence_minutes: silence.in_minutes.to_i, paid_without_webhook: paid_without_webhook_count,
          recent_payment_attempts: recent_attempt_count, min_attempts: min_attempts, last_receipt_at: last_receipt_at&.iso8601 }
      else
        {}
      end
    end

    # True only when the thing that opened the incident was put right after it
    # opened, not merely when evidence aged out of its window or an unrelated
    # webhook arrived.
    #
    #   failures    A receipt was processed after the incident opened AND none
    #               of the incident's failed or hung receipts is still failed.
    #   silent      A payment_intent.succeeded receipt was processed after the
    #               incident opened (a charge.updated or any other event type
    #               doesn't count) AND no paid-but-unconfirmed payment from the
    #               last 7 days is still waiting for its success receipt.
    #   unverified  A verified delivery (a stored receipt) arrived after the
    #               incident opened.
    def affirmative_recovery?(name, since:)
      case name
      when "stripe_webhook_failures"
        receipts.processed.where(processed_at: (since + 1.second)..).exists? && unresolved_count(name, since: since).zero?
      when "stripe_webhooks_silent"
        success_receipt_since?(since) && unresolved_count(name, since: since).zero?
      when "stripe_unverified_deliveries"
        receipts.where(created_at: (since + 1.second)..).exists?
      else
        false
      end
    end

    # Rows that still need a person even though the signal went quiet.
    def unresolved_count(name, since: nil)
      case name
      when "stripe_webhook_failures"
        failed_since = (since || (now - UNRESOLVED_LOOKBACK)) - failure_window
        receipts.failed.where(updated_at: failed_since..).count + stuck_processing_count
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
        unverified_failing: unverified_alert_count.positive?,
        thresholds: {
          failure_window_minutes: failure_window.in_minutes.to_i, failure_threshold: failure_threshold,
          unverified_threshold: unverified_threshold,
          silence_minutes: silence.in_minutes.to_i, silence_lookback_minutes: lookback.in_minutes.to_i,
          silence_min_attempts: min_attempts
        }
      }
    end

    private

    attr_reader :now, :mode

    def failure_window = self.class.env_integer("HAFAPASS_WEBHOOK_FAILURE_WINDOW_MINUTES").minutes
    def failure_threshold = self.class.env_integer("HAFAPASS_WEBHOOK_FAILURE_THRESHOLD")
    def unverified_threshold = self.class.env_integer("HAFAPASS_WEBHOOK_UNVERIFIED_THRESHOLD")
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

    # Real deliveries look missing: no verified receipt for the silence window
    # while payments were started or paid. Rejections alone never page.
    def deliveries_missing?
      !webhooks_arriving? && (recent_attempt_count >= 1 || paid_without_webhook_count >= 1)
    end

    def unverified_over_threshold?
      rejected_in_window >= unverified_threshold
    end

    def unverified_alert_count
      unverified_over_threshold? && deliveries_missing? ? rejected_in_window : 0
    end

    # Enough rejections to notice, but no sign real deliveries are missing:
    # recorded at info level, never paged.
    def unverified_note_count
      unverified_over_threshold? && !deliveries_missing? ? rejected_in_window : 0
    end

    def success_receipt_since?(since)
      PaymentEvent.where(event_type: SUCCESS_EVENT, created_at: (since + 1.second)..)
        .where(webhook_event_id: receipts.processed.select(:id)).exists?
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
