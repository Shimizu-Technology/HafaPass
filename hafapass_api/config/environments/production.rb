require "active_support/core_ext/integer/time"
require_relative "../runtime_configuration"

if Rails.env.production? && ActiveModel::Type::Boolean.new.cast(ENV["HAFAPASS_PROVIDER_REHEARSAL"])
  raise "Provider rehearsal requires an isolated staging environment"
end

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  config.log_tags = [:request_id]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")
  config.active_support.report_deprecations = false
  config.active_record.dump_schema_after_migration = false
  config.active_record.attributes_for_inspect = [:id]
  config.i18n.fallbacks = true
  config.force_ssl = true
  # Render's liveness probe is boot-only and may arrive through its internal
  # HTTP path. Application requests still redirect to HTTPS and receive HSTS.
  config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }
  config.hosts = [RuntimeConfiguration.public_api_host] if Rails.env.production?
  config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
