# frozen_string_literal: true

require "uri"

module ReleaseMigrationConfiguration
  module_function

  def apply!(environment: ENV)
    return unless %w[production staging].include?(environment.fetch("RAILS_ENV", "development"))

    url = environment["DATABASE_MIGRATION_URL"].to_s
    uri = URI.parse(url)
    unless %w[postgres postgresql].include?(uri.scheme) && uri.host && uri.path.length > 1 &&
        !uri.host.include?("-pooler")
      raise ArgumentError, "DATABASE_MIGRATION_URL must be a direct PostgreSQL connection"
    end

    application = URI.parse(environment["DATABASE_URL"].to_s)
    unless application.path == uri.path
      raise ArgumentError, "DATABASE_MIGRATION_URL must select the configured application database"
    end

    if environment["RAILS_ENV"] == "staging" && !uri.path.match?(/\A\/[a-zA-Z0-9_]*staging[a-zA-Z0-9_]*\z/)
      raise ArgumentError, "DATABASE_MIGRATION_URL must select the dedicated staging database"
    end

    environment["DATABASE_URL"] = url
    environment["STAGING_DATABASE_URL"] = url if environment["RAILS_ENV"] == "staging"
  rescue URI::InvalidURIError
    raise ArgumentError, "DATABASE_MIGRATION_URL must be a direct PostgreSQL connection"
  end
end
