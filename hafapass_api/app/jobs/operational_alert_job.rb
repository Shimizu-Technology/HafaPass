# frozen_string_literal: true

# Every five minutes, check each operational signal that needs a person and
# raise one Sentry message for it when its count rose since the last check, or
# at most every REPEAT_INTERVAL while it stays non-zero. Some counts (failed
# webhooks, open reconciliation exceptions) stand until a person clears them;
# re-alerting those every run would only train people to ignore the alert.
# The last count and alert time live in runtime_alert_states, so a deploy or
# restart doesn't re-alert. A stable fingerprint keeps each signal in one
# Sentry issue; only the signal name and count leave the app.
#
# The Stripe webhook signals (Operations::StripeWebhookHealth) are incidents
# with a lifecycle instead:
#   - opening or standing: one alert, repeated every INCIDENT_REPEAT_INTERVAL
#     (more evidence during the same incident is not a new alert, and a signal
#     that re-opens inside that interval does not page again);
#   - clearing: if something worked after the incident opened (a webhook was
#     processed) it sends "recovered"; if the evidence only aged out of its
#     window it sends "quiet" with the rows that still need a person. Both are
#     info level with their own fingerprints, so neither reopens the alert's
#     issue nor matches a level:error rule.
# One signal that raises an error never stops the others.
class OperationalAlertJob < ApplicationJob
  queue_as :low

  EXHAUSTED_DELIVERY_ATTEMPTS = 5
  EXHAUSTED_DELIVERY_WINDOW = 24.hours
  FAILED_JOB_WINDOW = 1.hour
  REPEAT_INTERVAL = 6.hours
  INCIDENT_SIGNALS = Operations::StripeWebhookHealth::SIGNALS
  INCIDENT_REPEAT_INTERVAL = 1.hour

  def perform
    now = Time.current
    health = Operations::StripeWebhookHealth.new(now: now)
    signals = self.class.signals(now: now, health: health)
    states = RuntimeAlertState.where(signal: signals.keys).index_by(&:signal)
    signals.each do |signal, count|
      state = states[signal] || RuntimeAlertState.new(signal: signal)
      if INCIDENT_SIGNALS.include?(signal)
        handle_incident(signal, count, state, now, health)
      else
        handle_standing(signal, count, state, now)
      end
      state.last_count = count
      state.save! if state.new_record? ? (count.positive? || state.incident_opened_at.present?) : state.changed?
    rescue StandardError => e
      report_failure(signal, e)
    end
  end

  # Counts by signal. A signal whose query fails is reported to Sentry and left
  # out (its state is untouched), so it can't hide the others.
  def self.signals(now: Time.current, health: Operations::StripeWebhookHealth.new(now: now))
    sources = {
      "exhausted_message_deliveries" => -> {
        MessageDelivery.failed.where(attempts: EXHAUSTED_DELIVERY_ATTEMPTS..)
          .where(failed_at: (now - EXHAUSTED_DELIVERY_WINDOW)..).count
      },
      "failed_payment_webhooks" => -> { WebhookEvent.failed.count },
      "open_reconciliation_exceptions" => -> { ReconciliationException.open.count },
      "failed_background_jobs" => -> { failed_background_jobs(now) }
    }
    INCIDENT_SIGNALS.each { |signal| sources[signal] = -> { health.signal(signal) } }
    sources.each_with_object({}) do |(signal, source), result|
      result[signal] = source.call
    rescue StandardError => e
      new.send(:report_failure, signal, e)
    end
  end

  def self.failed_background_jobs(now)
    return 0 unless SolidQueue::FailedExecution.table_exists?

    SolidQueue::FailedExecution.where(created_at: (now - FAILED_JOB_WINDOW)..).count
  end

  private

  def handle_standing(signal, count, state, now)
    return unless count.positive? && standing_alert_due?(state, count, now)

    alert(signal, count)
    state.last_alerted_at = now
  end

  def standing_alert_due?(state, count, now)
    state.last_alerted_at.nil? || count > state.last_count || state.last_alerted_at <= now - REPEAT_INTERVAL
  end

  def handle_incident(signal, count, state, now, health)
    if count.positive?
      state.incident_opened_at ||= now
      return unless state.last_alerted_at.nil? || state.last_alerted_at <= now - INCIDENT_REPEAT_INTERVAL

      alert(signal, count, health.details(signal))
      state.last_alerted_at = now
    elsif state.last_count.positive? || state.incident_opened_at
      opened_at = state.incident_opened_at || state.last_alerted_at || state.updated_at
      paged = state.last_alerted_at.present? && state.last_alerted_at >= opened_at
      if paged
        if health.affirmative_recovery?(signal, since: opened_at)
          recover(signal)
        else
          quiet(signal, health.unresolved_count(signal))
        end
      end
      state.incident_opened_at = nil
    end
  end

  def alert(signal, count, extra = {})
    Rails.logger.warn({ event: "operational_alert", signal: signal, count: count }.to_json)
    Sentry.capture_message("Operational alert: #{signal}", level: :error,
      fingerprint: ["operational-alert", signal], tags: { operational_signal: signal }, extra: { count: count }.merge(extra))
  end

  # A webhook was processed after the incident opened: the path works again.
  def recover(signal)
    Rails.logger.info({ event: "operational_alert_recovered", signal: signal }.to_json)
    Sentry.capture_message("Operational alert recovered: #{signal}", level: :info,
      fingerprint: ["operational-alert-recovered", signal],
      tags: { operational_signal: signal, operational_state: "recovered" })
  end

  # The evidence left its window but nothing proved the path works again.
  def quiet(signal, unresolved)
    Rails.logger.info({ event: "operational_alert_quiet", signal: signal, unresolved: unresolved }.to_json)
    Sentry.capture_message("Operational alert quiet, not confirmed recovered: #{signal}", level: :info,
      fingerprint: ["operational-alert-quiet", signal],
      tags: { operational_signal: signal, operational_state: "quiet" },
      extra: { unresolved_rows: unresolved,
               note: "No new evidence in the alert window, but no webhook has been processed since it opened." })
  end

  def report_failure(signal, error)
    Rails.logger.error({ event: "operational_alert_check_failed", signal: signal, error_class: error.class.name }.to_json)
    Sentry.capture_exception(error, tags: { operational_signal: signal, operational_state: "check_failed" })
  end
end
