# frozen_string_literal: true

# Every five minutes, check each operational signal that needs a person and
# raise one Sentry message for it when its count rose since the last check, or
# at most every REPEAT_INTERVAL while it stays non-zero. Some counts (failed
# webhooks, open reconciliation exceptions) stand until a person clears them;
# re-alerting those every run would only train people to ignore the alert.
# The last count and alert time live in runtime_alert_states, so a deploy or
# restart doesn't re-alert. A stable fingerprint keeps each signal in one
# Sentry issue; only the signal name and count leave the app.
class OperationalAlertJob < ApplicationJob
  queue_as :low

  EXHAUSTED_DELIVERY_ATTEMPTS = 5
  EXHAUSTED_DELIVERY_WINDOW = 24.hours
  FAILED_JOB_WINDOW = 1.hour
  REPEAT_INTERVAL = 6.hours

  def perform
    now = Time.current
    signals = self.class.signals(now: now)
    states = RuntimeAlertState.where(signal: signals.keys).index_by(&:signal)
    signals.each do |signal, count|
      state = states[signal] || RuntimeAlertState.new(signal: signal)
      if count.positive? && alert_due?(state, count, now)
        alert(signal, count)
        state.last_alerted_at = now
      end
      state.last_count = count
      state.save! if state.new_record? ? count.positive? : state.changed?
    end
  end

  def self.signals(now: Time.current)
    {
      "exhausted_message_deliveries" => MessageDelivery.failed.where(attempts: EXHAUSTED_DELIVERY_ATTEMPTS..)
        .where(failed_at: (now - EXHAUSTED_DELIVERY_WINDOW)..).count,
      "failed_payment_webhooks" => WebhookEvent.failed.count,
      "open_reconciliation_exceptions" => ReconciliationException.open.count,
      "failed_background_jobs" => failed_background_jobs(now)
    }
  end

  def self.failed_background_jobs(now)
    return 0 unless SolidQueue::FailedExecution.table_exists?

    SolidQueue::FailedExecution.where(created_at: (now - FAILED_JOB_WINDOW)..).count
  end

  private

  def alert_due?(state, count, now)
    state.last_alerted_at.nil? || count > state.last_count || state.last_alerted_at <= now - REPEAT_INTERVAL
  end

  def alert(signal, count)
    Rails.logger.warn({ event: "operational_alert", signal: signal, count: count }.to_json)
    Sentry.capture_message("Operational alert: #{signal}", level: :error,
      fingerprint: ["operational-alert", signal], tags: { operational_signal: signal }, extra: { count: count })
  end
end
