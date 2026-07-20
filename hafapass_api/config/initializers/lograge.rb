# frozen_string_literal: true

Rails.application.configure do
  config.lograge.enabled = true
  config.lograge.formatter = Lograge::Formatters::Json.new
  config.lograge.custom_options = lambda do |event|
    {
      service: "hafapass-api",
      environment: Rails.env,
      request_id: event.payload[:request_id],
      user_id: event.payload[:user_id]
    }.compact
  end
end
