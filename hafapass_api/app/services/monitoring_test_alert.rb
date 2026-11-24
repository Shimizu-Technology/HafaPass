# frozen_string_literal: true

# Sends one clearly labelled test event to Sentry so Leon can prove an alert
# rule reaches his phone (docs/MONITORING_SETUP.md). The event carries the same
# tag the real alert does, so the rule's filter matches it, plus
# monitoring_test=true and a "[TEST]" message. Its fingerprint is its own,
# so it never joins a real issue, and nothing in the app's alert state changes.
class MonitoringTestAlert
  SIGNAL_KINDS = %w[exhausted_message_deliveries failed_payment_webhooks open_reconciliation_exceptions
    failed_background_jobs stripe_webhook_failures stripe_unverified_deliveries stripe_webhooks_silent].freeze
  AREA_KINDS = MonitoringArea::AREAS.freeze
  KINDS = (SIGNAL_KINDS + AREA_KINDS + ["sentry_connectivity"]).freeze
  COOLDOWN = 30.seconds
  COOLDOWN_SIGNAL = "monitoring_test_alert"

  # One shared cooldown for the button and the rake task (durable, so it holds
  # across web processes), claimed with a single conditional UPDATE: of two
  # simultaneous requests, one wins. Returns true when the caller may send.
  def self.claim_slot!(now: Time.current)
    begin
      RuntimeAlertState.create!(signal: COOLDOWN_SIGNAL, last_alerted_at: now)
      return true
    rescue ActiveRecord::RecordNotUnique
      nil
    end
    RuntimeAlertState.where(signal: COOLDOWN_SIGNAL)
      .where("last_alerted_at IS NULL OR last_alerted_at <= ?", now - COOLDOWN)
      .update_all(last_alerted_at: now, updated_at: now).positive?
  end

  # A send that never reached the SDK's queue didn't use up the slot.
  def self.release_slot!
    RuntimeAlertState.where(signal: COOLDOWN_SIGNAL).update_all(last_alerted_at: nil)
  end

  # Returns the Sentry event id once Sentry accepted the event, or nil.
  #
  # Sent synchronously (hint background: false), not through the SDK's
  # background queue. sentry-ruby returns an event object even when that queue
  # is full and silently drops the event, so a queued send can't prove
  # anything. Here the HTTP request to Sentry happens before this returns: a
  # network error, a non-2xx response, an unconfigured environment, a rate-limited
  # project or an event dropped before sending all return nil.
  def self.send!(kind:, actor: nil)
    raise ArgumentError, "Unknown test alert kind" unless KINDS.include?(kind)

    tags = { monitoring_test: "true", test_alert_kind: kind }
    tags[:operational_signal] = kind if SIGNAL_KINDS.include?(kind)
    tags[:area] = kind if AREA_KINDS.include?(kind)
    tags.merge!(integration: "stripe_webhook", operation: "webhook_processing") if kind == "webhook"

    Rails.logger.warn({ event: "monitoring_test_alert", kind: kind, actor_user_id: actor&.id }.to_json)
    transport = Sentry.get_current_client&.transport
    return nil if transport&.is_rate_limited?("error")

    event = Sentry.capture_message("[TEST] HafaPass monitoring test alert: #{kind}", level: :error,
      fingerprint: ["monitoring-test-alert", kind], tags: tags, hint: { background: false },
      extra: { note: "Sent on purpose by an admin to test alert routing. Nothing is wrong.", sent_at: Time.current.iso8601 })
    return nil if event.nil? || transport&.is_rate_limited?("error")

    event.event_id
  end
end
