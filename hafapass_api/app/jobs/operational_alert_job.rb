# frozen_string_literal: true

# Every five minutes, raise one Sentry message per operational signal that
# needs a person. A stable fingerprint keeps each signal in one Sentry issue,
# so alert rules can route it; only the signal name and count leave the app.
class OperationalAlertJob < ApplicationJob
  queue_as :low

  EXHAUSTED_DELIVERY_ATTEMPTS = 5
  EXHAUSTED_DELIVERY_WINDOW = 24.hours
  FAILED_JOB_WINDOW = 1.hour

  def perform
    self.class.signals.each do |signal, count|
      next unless count.positive?

      Rails.logger.warn({ event: "operational_alert", signal: signal, count: count }.to_json)
      Sentry.capture_message("Operational alert: #{signal}", level: :error,
        fingerprint: ["operational-alert", signal], tags: { operational_signal: signal }, extra: { count: count })
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
end
