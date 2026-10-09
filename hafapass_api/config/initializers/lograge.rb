# frozen_string_literal: true

require Rails.root.join("lib/telemetry_privacy")

Rails.application.configure do
  config.lograge.enabled = Rails.env.production? || Rails.env.staging?
  config.lograge.formatter = Lograge::Formatters::Json.new
  config.lograge.before_format = ->(data, _payload) { TelemetryPrivacy.scrub(data) }
  config.lograge.custom_options = lambda do |event|
    {
      service: "hafapass-api",
      environment: Rails.env,
      request_id: event.payload[:request_id],
      user_id: event.payload[:user_id]
    }.compact
  end
end
