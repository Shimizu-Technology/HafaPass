# frozen_string_literal: true

require_relative "production"
require_relative "../../app/services/stage_safety"

StageSafety.validate!

Rails.application.configure do
  config.force_ssl = true
  config.hosts = [URI.parse(ENV.fetch("PUBLIC_API_URL")).host]
end
