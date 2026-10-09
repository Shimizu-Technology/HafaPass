# frozen_string_literal: true

require "rails_helper"
require "erb"
require "yaml"
require Rails.root.join("config/runtime_configuration").to_s
require Rails.root.join("config/release_migration_configuration").to_s

RSpec.describe RuntimeConfiguration do
  around do |example|
    names = %w[RAILS_MAX_THREADS SIDEKIQ_CONCURRENCY DB_POOL PUBLIC_API_URL]
    original = names.index_with { |name| ENV[name] }
    names.each { |name| ENV.delete(name) }
    example.run
  ensure
    original.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  it "uses a conservative worker capacity covered by the shared database pool" do
    expect(described_class.web_threads).to eq(3)
    expect(described_class.worker_concurrency).to eq(3)
    expect(described_class.database_pool).to eq(5)
    erb = ERB.new(Rails.root.join("config/sidekiq.yml").read)
    erb.filename = Rails.root.join("config/sidekiq.yml").to_s
    expect(YAML.safe_load(erb.result, permitted_classes: [Symbol])[:concurrency]).to eq(3)
  end

  it "rejects a pool smaller than configured request or job concurrency" do
    ENV["SIDEKIQ_CONCURRENCY"] = "6"
    expect { described_class.database_pool }.to raise_error(ArgumentError, /DB_POOL must cover/)
    ENV["DB_POOL"] = "6"
    expect(described_class.database_pool).to eq(6)
    ENV["RAILS_MAX_THREADS"] = "7"
    expect { described_class.database_pool }.to raise_error(ArgumentError, /DB_POOL must cover/)
  end

  it "does not silently coerce invalid worker capacity" do
    %w[0 -1 3x false].each do |value|
      ENV["SIDEKIQ_CONCURRENCY"] = value
      expect { described_class.database_pool }.to raise_error(ArgumentError, /positive integer/)
    end
  end

  it "accepts only an exact HTTPS API origin" do
    ENV["PUBLIC_API_URL"] = "https://api.hafapass.example/"
    expect(described_class.public_api_host).to eq("api.hafapass.example")
    [nil, "http://api.example", "https://user:secret@api.example", "https://api.example/path",
      "https://api.example?query=1", "https://api.example#fragment"].each do |value|
      value.nil? ? ENV.delete("PUBLIC_API_URL") : ENV["PUBLIC_API_URL"] = value
      expect { described_class.public_api_host }.to raise_error(ArgumentError, /HTTPS origin/)
    end
  end
end

RSpec.describe ReleaseMigrationConfiguration do
  it "uses the direct connection only inside the release process" do
    env = { "RAILS_ENV" => "production", "DATABASE_URL" => "postgresql://pooler/app",
      "DATABASE_MIGRATION_URL" => "postgresql://direct/app?sslmode=require" }
    described_class.apply!(environment: env)
    expect(env["DATABASE_URL"]).to eq(env["DATABASE_MIGRATION_URL"])
  end

  it "keeps the staging aliases bound to the same dedicated direct database" do
    env = { "RAILS_ENV" => "staging", "DATABASE_URL" => "postgresql://pooler/app_staging",
      "DATABASE_MIGRATION_URL" => "postgresql://direct/app_staging?sslmode=require" }
    described_class.apply!(environment: env)
    expect(env.values_at("DATABASE_URL", "STAGING_DATABASE_URL")).to eq([env["DATABASE_MIGRATION_URL"]] * 2)
    env["DATABASE_MIGRATION_URL"] = "postgresql://direct/app_production"
    expect { described_class.apply!(environment: env) }.to raise_error(ArgumentError, /configured application database/)
  end

  it "rejects missing and pooled release URLs without revealing their values" do
    [nil, "postgresql://user:secret@ep-foo-pooler.neon.tech/app", "not a URL"].each do |url|
      env = { "RAILS_ENV" => "production", "DATABASE_MIGRATION_URL" => url }
      expect { described_class.apply!(environment: env) }.to raise_error(ArgumentError, /direct PostgreSQL/)
      expect(env["DATABASE_URL"]).to be_nil
    end
  end

  it "does not require or override local development and test connections" do
    %w[development test].each do |name|
      env = { "RAILS_ENV" => name, "DATABASE_URL" => "postgresql://localhost/local" }
      expect { described_class.apply!(environment: env) }.not_to change { env }
    end
  end

  it "rejects a release URL targeting a different database" do
    env = { "RAILS_ENV" => "production", "DATABASE_URL" => "postgresql://pooled/app",
      "DATABASE_MIGRATION_URL" => "postgresql://direct/other" }
    expect { described_class.apply!(environment: env) }.to raise_error(ArgumentError, /configured application database/)
    expect(env["DATABASE_URL"]).to eq("postgresql://pooled/app")
  end
end
