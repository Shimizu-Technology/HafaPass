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

    # Production jobs must be durable and processed by the separately deployed
    # Sidekiq worker. Development may use the in-process adapter when Redis is
    # intentionally absent; tests configure Active Job's test adapter.
    config.active_job.queue_adapter = if Rails.env.test?
      :test
    elsif Rails.env.development? && ENV["REDIS_URL"].blank?
      :async
    else
      :sidekiq
    end

    # Enable Rack::Attack for rate limiting
    config.middleware.use Rack::Attack
  end
end
