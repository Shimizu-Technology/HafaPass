# frozen_string_literal: true

require "uri"

# Shared by Puma, Sidekiq and Active Record so their capacity cannot drift.
module RuntimeConfiguration
  module_function

  def web_threads
    positive_integer("RAILS_MAX_THREADS", 3)
  end

  def worker_concurrency
    positive_integer("SIDEKIQ_CONCURRENCY", 3)
  end

  def database_pool
    pool = positive_integer("DB_POOL", 5)
    if pool < [web_threads, worker_concurrency].max
      raise ArgumentError, "DB_POOL must cover RAILS_MAX_THREADS and SIDEKIQ_CONCURRENCY"
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

  def positive_integer(name, default)
    value = ENV.fetch(name, default.to_s)
    raise ArgumentError, "#{name} must be a positive integer" unless value.match?(/\A[1-9]\d*\z/)

    value.to_i
  end
end
