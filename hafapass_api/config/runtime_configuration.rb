# frozen_string_literal: true

require "uri"
require "securerandom"

# Shared by Puma, Sidekiq and Active Record so their capacity cannot drift.
module RuntimeConfiguration
  module_function

  def profile
    value = ENV.fetch("HAFAPASS_RUNTIME", "sidekiq")
    raise ArgumentError, "HAFAPASS_RUNTIME must be embedded, solid_queue, or sidekiq" unless %w[embedded solid_queue sidekiq].include?(value)

    value
  end

  def embedded?
    profile == "embedded"
  end

  def instance_id
    @instance_id ||= SecureRandom.uuid
  end

  def solid_queue?
    %w[embedded solid_queue].include?(profile)
  end

  def web_threads
    positive_integer("RAILS_MAX_THREADS", 3)
  end

  def worker_concurrency
    positive_integer("SIDEKIQ_CONCURRENCY", 3)
  end

  def database_pool
    pool = positive_integer("DB_POOL", solid_queue? ? 10 : 5)
    minimum = embedded? ? web_threads + 6 : (solid_queue? ? [web_threads, 7].max : [web_threads, worker_concurrency].max)
    if pool < minimum
      raise ArgumentError, "DB_POOL must cover RAILS_MAX_THREADS and SIDEKIQ_CONCURRENCY" unless solid_queue?
      raise ArgumentError, "DB_POOL must cover request/job threads and Solid Queue supervision"
    end

    pool
  end

  def public_api_host
    uri = URI.parse(ENV.fetch("PUBLIC_API_URL", "").delete_suffix("/"))
    unless uri.is_a?(URI::HTTPS) && uri.host && uri.userinfo.nil? && uri.path.empty? &&
        uri.query.nil? && uri.fragment.nil?
      raise ArgumentError, "PUBLIC_API_URL must be an HTTPS origin"
    end

    uri.host
  rescue URI::InvalidURIError
    raise ArgumentError, "PUBLIC_API_URL must be an HTTPS origin"
  end

  LOCAL_CORS_ORIGINS = %w[http://localhost:5173 http://localhost:5174 http://localhost:5175 http://localhost:5176].freeze

  # Browser origins allowed by CORS. Every deployed environment (staging and
  # production) must list its own; only development and test use local Vite.
  def allowed_origins(local:)
    origins = ENV["ALLOWED_ORIGINS"].to_s.split(",").map(&:strip).reject(&:empty?)
    return origins if origins.any?
    raise KeyError, "ALLOWED_ORIGINS must list the public site origins in every deployed environment" unless local

    LOCAL_CORS_ORIGINS
  end

  def positive_integer(name, default)
    value = ENV.fetch(name, default.to_s)
    raise ArgumentError, "#{name} must be a positive integer" unless value.match?(/\A[1-9]\d*\z/)

    value.to_i
  end
end
