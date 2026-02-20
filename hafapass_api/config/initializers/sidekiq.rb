# frozen_string_literal: true

# Sidekiq configuration for background job processing
# https://github.com/sidekiq/sidekiq

if defined?(Sidekiq)
  redis_url = if Rails.env.production?
    ENV.fetch("REDIS_URL") # Fail loudly in production if REDIS_URL is missing
  else
    ENV.fetch("REDIS_URL", "redis://localhost:6379/0")
  end

  Sidekiq.configure_server do |config|
    config.redis = { url: redis_url }

    # Configure server-side logger
    config.logger.level = Rails.env.production? ? Logger::WARN : Logger::INFO
  end

  Sidekiq.configure_client do |config|
    config.redis = { url: redis_url }
  end
end
