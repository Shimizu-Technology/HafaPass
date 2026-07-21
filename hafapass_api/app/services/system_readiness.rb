# frozen_string_literal: true

class SystemReadiness
  class << self
    def call
      checks = {
        database: database_check,
        job_queue: job_queue_check,
        worker: worker_check,
        commerce_clock: commerce_clock_check,
        configuration: ProductionConfiguration.call,
        providers: provider_configuration,
        operations: operational_signals
      }

      required_checks = checks.values_at(:database, :job_queue)
      required_checks.concat(checks.values_at(:worker, :commerce_clock, :configuration)) if Rails.env.production?

      {
        status: required_checks.all? { |check| check[:ready] } ? "ready" : "not_ready",
        timestamp: Time.current.iso8601,
        checks: checks
      }
    end

    private

    def database_check
      ActiveRecord::Base.connection.select_value("SELECT 1")
      { ready: true, status: "connected" }
    rescue StandardError => e
      failure("unavailable", e)
    end

    def job_queue_check
      adapter = ActiveJob::Base.queue_adapter_name
      return { ready: true, status: "development_async", adapter: adapter } if adapter == "async"
      return { ready: true, status: "test", adapter: adapter } if adapter == "test"
      return { ready: false, status: "redis_not_configured", adapter: adapter } if ENV["REDIS_URL"].blank?

      Sidekiq.redis { |connection| connection.call("PING") }
      { ready: true, status: "connected", adapter: adapter }
    rescue StandardError => e
      failure("unavailable", e, adapter: adapter)
    end

    def worker_check
      return { ready: true, status: "not_required", processes: 0 } unless ActiveJob::Base.queue_adapter_name == "sidekiq"
      return { ready: false, status: "redis_not_configured", processes: 0 } if ENV["REDIS_URL"].blank?

      require "sidekiq/api"
      process_count = Sidekiq::ProcessSet.new.size
      {
        ready: !Rails.env.production? || process_count.positive?,
        status: process_count.positive? ? "active" : "no_active_process",
        processes: process_count
      }
    rescue StandardError => e
      failure("unavailable", e, processes: 0)
    end

    def provider_configuration
      {
        clerk: configured?("CLERK_SECRET_KEY"),
        email: configured?("RESEND_API_KEY"),
        email_webhook: configured?("RESEND_WEBHOOK_SECRET"),
        error_monitoring: configured?("SENTRY_DSN"),
        object_storage: %w[AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_BUCKET].all? { |key| ENV[key].present? },
        stripe_test: %w[STRIPE_TEST_SECRET_KEY STRIPE_TEST_PUBLISHABLE_KEY].all? { |key| ENV[key].present? },
        stripe_live: %w[STRIPE_LIVE_SECRET_KEY STRIPE_LIVE_PUBLISHABLE_KEY].all? { |key| ENV[key].present? }
      }
    end

    def commerce_clock_check
      return { ready: true, status: "not_required", lease_ttl_seconds: 0 } unless Rails.env.production?
      return { ready: false, status: "redis_not_configured", lease_ttl_seconds: 0 } if ENV["REDIS_URL"].blank?

      Operations::CommerceClockLease.status
    end

    def configured?(key)
      ENV[key].present?
    end

    def operational_signals
      {
        ready: true,
        status: "observable",
        failed_messages_last_hour: MessageDelivery.failed.where(updated_at: 1.hour.ago..).count,
        stale_message_events: MessageProviderEvent.where(processed_at: nil).where("received_at < ?", 5.minutes.ago).count,
        failed_payment_webhooks: WebhookEvent.failed.count,
        open_reconciliation_exceptions: ReconciliationException.open.count,
        unknown_card_present_results: CardPresentPaymentAttempt.status_result_unknown.count
      }
    rescue ActiveRecord::StatementInvalid
      { ready: true, status: "migration_pending" }
    end

    def failure(status, error, extra = {})
      Rails.logger.error(
        {
          event: "readiness_check_failed",
          error_class: error.class.name,
          status: status
        }.merge(extra).to_json
      )

      { ready: false, status: status }.merge(extra)
    end
  end
end
