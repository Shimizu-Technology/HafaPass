# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("config/release_migration_configuration").to_s

RSpec.describe "Deployed database configuration" do
  let(:pooled_url) { "postgresql://app:secret@ep-quiet-sky-pooler.us-east-2.aws.neon.tech/hafapass_staging?sslmode=require" }

  def deployed_configs(environment)
    yaml = ERB.new(Rails.root.join("config/database.yml").read).result
    configs = ActiveRecord::DatabaseConfigurations.new(YAML.safe_load(yaml, aliases: true))
    configs.configs_for(env_name: environment, name: "primary").configuration_hash
  end

  around do |example|
    original = ENV.to_h.slice("DATABASE_URL", "STAGING_DATABASE_URL")
    ENV["DATABASE_URL"] = pooled_url
    ENV["STAGING_DATABASE_URL"] = pooled_url
    example.run
  ensure
    %w[DATABASE_URL STAGING_DATABASE_URL].each { |key| original.key?(key) ? ENV[key] = original[key] : ENV.delete(key) }
  end

  %w[production staging].each do |environment|
    it "disables server-side prepared statements on the pooled #{environment} connection" do
      config = deployed_configs(environment)

      expect(config).to include(prepared_statements: false, host: "ep-quiet-sky-pooler.us-east-2.aws.neon.tech",
        database: "hafapass_staging")
    end
  end

  it "migrates through the direct Neon host, never the pooler" do
    env = { "RAILS_ENV" => "production", "DATABASE_URL" => pooled_url,
      "DATABASE_MIGRATION_URL" => pooled_url.sub("-pooler", "") }
    ReleaseMigrationConfiguration.apply!(environment: env)
    expect(URI.parse(env["DATABASE_URL"]).host).to eq("ep-quiet-sky.us-east-2.aws.neon.tech")

    expect(Rails.root.join("bin/release-migrate").read).to include("ReleaseMigrationConfiguration.apply!")
  end
end
