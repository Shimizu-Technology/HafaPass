# frozen_string_literal: true

require Rails.root.join("lib/telemetry_privacy")
require Rails.root.join("app/services/application_revision")

Sentry.init do |config|
  config.dsn = ENV["SENTRY_DSN"]
  config.environment = ENV.fetch("SENTRY_ENVIRONMENT", Rails.env)
  config.enabled_environments = ENV.fetch("SENTRY_ENABLED_ENVIRONMENTS", "production,staging").split(",")
  config.release = ApplicationRevision.current
  config.send_default_pii = false
  config.sample_rate = 1.0
  config.traces_sample_rate = ENV.fetch("SENTRY_TRACES_SAMPLE_RATE", "0.1").to_f
  config.breadcrumbs_logger = [:active_support_logger, :http_logger]
  config.excluded_exceptions += [
    "ActionController::BadRequest",
    "ActionController::RoutingError",
    "ActiveRecord::RecordNotFound"
  ]

  config.before_breadcrumb = ->(breadcrumb, _hint) { TelemetryPrivacy.breadcrumb(breadcrumb) }
  config.before_send = ->(event, _hint) { TelemetryPrivacy.event(event) }
  config.before_send_transaction = ->(event, _hint) { TelemetryPrivacy.event(event) }
end
