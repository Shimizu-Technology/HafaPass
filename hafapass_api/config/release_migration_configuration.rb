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
    unless %w[postgres postgresql].include?(application.scheme) && application.host &&
        application.path == uri.path && normalized_application_host(application.host) == uri.host.downcase &&
        (application.port || 5432) == (uri.port || 5432)
      raise ArgumentError, "DATABASE_MIGRATION_URL must select the configured application endpoint and database"
    end

    if environment["RAILS_ENV"] == "staging" && !uri.path.match?(/\A\/[a-zA-Z0-9_]*staging[a-zA-Z0-9_]*\z/)
      raise ArgumentError, "DATABASE_MIGRATION_URL must select the dedicated staging database"
    end

    environment["DATABASE_URL"] = url
    environment["STAGING_DATABASE_URL"] = url if environment["RAILS_ENV"] == "staging"
  rescue URI::InvalidURIError
    raise ArgumentError, "DATABASE_MIGRATION_URL must be a direct PostgreSQL connection"
  end

  def normalized_application_host(host)
    host = host.downcase
    # Neon assigns the same database name to many unrelated branches/projects.
    # Only its documented pooled/direct hostname pair may differ. Other
    # providers must use the same host and port until a mapping is reviewed.
    return host unless host.end_with?(".neon.tech")

    host.sub(/\A([^.]+)-pooler(\..+)\z/, '\\1\\2')
  end
end
