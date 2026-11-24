# frozen_string_literal: true

# Sends one clearly labelled test event to Sentry so Leon can prove an alert
# rule reaches his phone (docs/MONITORING_SETUP.md). The event carries the same
# tag the real alert does, so the rule's filter matches it, plus
# monitoring_test=true and a "[TEST]" message. Its fingerprint is its own,
# so it never joins a real issue, and nothing in the app's alert state changes.
class MonitoringTestAlert
  SIGNAL_KINDS = %w[exhausted_message_deliveries failed_payment_webhooks open_reconciliation_exceptions
    failed_background_jobs stripe_webhook_failures stripe_webhooks_silent].freeze
  AREA_KINDS = MonitoringArea::AREAS.freeze
  KINDS = (SIGNAL_KINDS + AREA_KINDS + ["sentry_connectivity"]).freeze

  def self.send!(kind:, actor: nil)
    raise ArgumentError, "Unknown test alert kind" unless KINDS.include?(kind)

    tags = { monitoring_test: "true", test_alert_kind: kind }
    tags[:operational_signal] = kind if SIGNAL_KINDS.include?(kind)
    tags[:area] = kind if AREA_KINDS.include?(kind)
    tags.merge!(integration: "stripe_webhook", operation: "webhook_processing") if kind == "webhook"

    Rails.logger.warn({ event: "monitoring_test_alert", kind: kind, actor_user_id: actor&.id }.to_json)
    event = Sentry.capture_message("[TEST] HafaPass monitoring test alert: #{kind}", level: :error,
      fingerprint: ["monitoring-test-alert", kind], tags: tags,
      extra: { note: "Sent on purpose by an admin to test alert routing. Nothing is wrong.", sent_at: Time.current.iso8601 })
    event&.event_id
  end
end
