# frozen_string_literal: true

Sentry.init do |config|
  config.dsn = ENV["SENTRY_DSN"]
  config.environment = ENV.fetch("SENTRY_ENVIRONMENT", Rails.env)
  config.enabled_environments = ENV.fetch("SENTRY_ENABLED_ENVIRONMENTS", "production,staging").split(",")
  config.release = ENV["GIT_SHA"] || ENV["COMMIT_REF"]
  config.send_default_pii = false
  config.sample_rate = 1.0
  config.traces_sample_rate = ENV.fetch("SENTRY_TRACES_SAMPLE_RATE", "0.1").to_f
  config.breadcrumbs_logger = [:active_support_logger, :http_logger]
  config.excluded_exceptions += [
    "ActionController::BadRequest",
    "ActionController::RoutingError",
    "ActiveRecord::RecordNotFound"
  ]

  config.before_send = lambda do |event, _hint|
    if event.request&.data.is_a?(Hash)
      filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
      event.request.data = filter.filter(event.request.data)
    elsif event.request
      event.request.data = nil
    end
    event
  end
end
