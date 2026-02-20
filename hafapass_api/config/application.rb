require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_record/railtie"
require "active_job/railtie"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_view/railtie"

Bundler.require(*Rails.groups)

module HafapassApi
  class Application < Rails::Application
    config.load_defaults 8.0
    config.autoload_lib(ignore: %w[assets tasks])
    config.api_only = true

    # Use Sidekiq for background jobs
    # Falls back to async (in-process) if Redis is not available
    config.active_job.queue_adapter = ENV["REDIS_URL"].present? ? :sidekiq : :async

    # Enable Rack::Attack for rate limiting
    config.middleware.use Rack::Attack
  end
end
