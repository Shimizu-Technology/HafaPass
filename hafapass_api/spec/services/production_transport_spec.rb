# frozen_string_literal: true

require "rails_helper"
require "open3"

RSpec.describe "Production transport and platform liveness" do
  let(:encryption_environment) do
    %w[PRIMARY_KEY DETERMINISTIC_KEY KEY_DERIVATION_SALT].to_h do |suffix|
      ["ACTIVE_RECORD_ENCRYPTION_#{suffix}", Digest::SHA256.hexdigest("production-probe-fixture-#{suffix}")]
    end
  end

  it "boots without dependencies, accepts only its API host, and enforces HTTPS outside /up" do
    environment = {
      "RAILS_ENV" => "production", "PUBLIC_API_URL" => "https://api.hafapass.example",
      "ALLOWED_ORIGINS" => "https://hafapass.example",
      "FRONTEND_URL" => "https://hafapass.example", "PUBLIC_WEB_URL" => "https://hafapass.example", "SECRET_KEY_BASE" => SecureRandom.hex(64),
      "DATABASE_URL" => "postgresql://localhost:54399/hafapass_unreachable",
      "REDIS_URL" => "redis://localhost:63899/1", "SENTRY_DSN" => ""
    }
    script = <<~RUBY
      require "rack/mock"
      class << ActiveRecord::Base
        def connection; raise "liveness touched database"; end
      end
      def Sidekiq.redis; raise "liveness touched queue"; end
      client = Rack::MockRequest.new(Rails.application)
      results = [
        client.get("/up", "HTTP_HOST" => "internal-platform-probe").status,
        client.get("/api/v1/health", "HTTP_HOST" => "api.hafapass.example").status,
        client.get("/api/v1/health", "HTTP_HOST" => "api.hafapass.example", "HTTPS" => "on").status,
        client.get("/api/v1/health", "HTTP_HOST" => "untrusted.example", "HTTPS" => "on").status
      ]
      puts "PROBE_STATUSES=" + results.join(",")
    RUBY
    output, errors, status = Open3.capture3(environment.merge(encryption_environment), "bundle", "exec", "rails", "runner", script,
      chdir: Rails.root)

    expect(status.success?).to be(true), "Production probe process failed: #{errors}"
    expect(output).to include("PROBE_STATUSES=200,301,200,403")
  end

  it "refuses production boot when an encryption key is missing" do
    environment = encryption_environment.merge("RAILS_ENV" => "production", "HAFAPASS_RUNTIME" => "embedded",
      "PUBLIC_API_URL" => "https://api.hafapass.example", "ALLOWED_ORIGINS" => "https://hafapass.example",
      "FRONTEND_URL" => "https://hafapass.example", "PUBLIC_WEB_URL" => "https://hafapass.example",
      "SECRET_KEY_BASE" => SecureRandom.hex(64), "DATABASE_URL" => "postgresql://localhost:54399/unreachable",
      "SENTRY_DSN" => "", "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => nil)
    _output, errors, status = Open3.capture3(environment, "bundle", "exec", "rails", "runner", "puts :booted", chdir: Rails.root)
    expect(status.success?).to be(false)
    expect(errors).to include("ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY is required")
  end

  it "keeps embedded /up independent of its durable throttle database" do
    environment = { "RAILS_ENV" => "production", "HAFAPASS_RUNTIME" => "embedded",
      "PUBLIC_API_URL" => "https://api.hafapass.example", "ALLOWED_ORIGINS" => "https://hafapass.example",
      "FRONTEND_URL" => "https://hafapass.example", "PUBLIC_WEB_URL" => "https://hafapass.example",
      "SECRET_KEY_BASE" => SecureRandom.hex(64), "DATABASE_URL" => "postgresql://localhost:54399/unreachable",
      "SENTRY_DSN" => "" }
    script = <<~RUBY
      require "rack/mock"
      class << RuntimeThrottleBucket
        def connection; raise "liveness touched throttle database"; end
      end
      puts "BOOT_ONLY=" + Rack::MockRequest.new(Rails.application).get("/up", "HTTP_HOST" => "internal").status.to_s
    RUBY
    output, errors, status = Open3.capture3(environment.merge(encryption_environment), "bundle", "exec", "rails", "runner", script, chdir: Rails.root)
    expect(status.success?).to be(true), errors
    expect(output).to include("BOOT_ONLY=200")
  end

  it "boots with the same authoritative Render revision for Sentry and runtime process metadata" do
    environment = { "RAILS_ENV" => "production", "HAFAPASS_RUNTIME" => "embedded",
      "PUBLIC_API_URL" => "https://api.hafapass.example", "ALLOWED_ORIGINS" => "https://hafapass.example",
      "FRONTEND_URL" => "https://hafapass.example", "PUBLIC_WEB_URL" => "https://hafapass.example",
      "SECRET_KEY_BASE" => SecureRandom.hex(64), "DATABASE_URL" => "postgresql://localhost:54399/unreachable",
      "SENTRY_DSN" => "", "RENDER_GIT_COMMIT" => "c" * 40, "GIT_SHA" => "a" * 40, "COMMIT_REF" => "b" * 40 }
    script = <<~RUBY
      process_class = Class.new { def metadata; {}; end }
      process_class.prepend(Operations::SolidQueueProcessMetadata)
      puts "RELEASE_IDENTITIES=" + [ApplicationRevision.current, Sentry.configuration.release,
        process_class.new.metadata[:application_revision]].join(",")
    RUBY
    output, errors, status = Open3.capture3(environment.merge(encryption_environment), "bundle", "exec", "rails", "runner", script, chdir: Rails.root)
    expect(status.success?).to be(true), errors
    expect(output).to include("RELEASE_IDENTITIES=#{Array.new(3, 'c' * 40).join(',')}")
  end

  it "refuses to boot without the public site URLs or CORS origins instead of falling back to localhost" do
    base = { "RAILS_ENV" => "production", "HAFAPASS_RUNTIME" => "embedded",
      "PUBLIC_API_URL" => "https://api.hafapass.example", "ALLOWED_ORIGINS" => "https://hafapass.example",
      "FRONTEND_URL" => "https://hafapass.example", "PUBLIC_WEB_URL" => "https://hafapass.example",
      "SECRET_KEY_BASE" => SecureRandom.hex(64), "DATABASE_URL" => "postgresql://localhost:54399/unreachable",
      "SENTRY_DSN" => "" }
    {
      { "FRONTEND_URL" => nil, "PUBLIC_WEB_URL" => nil } => /FRONTEND_URL, PUBLIC_WEB_URL must be set/,
      { "PUBLIC_WEB_URL" => "http://hafapass.example" } => /PUBLIC_WEB_URL must be set/,
      { "ALLOWED_ORIGINS" => nil } => /ALLOWED_ORIGINS must list/
    }.each do |overrides, message|
      _output, errors, status = Open3.capture3(base.merge(encryption_environment).merge(overrides), "bundle", "exec", "rails", "runner", "puts :booted",
        chdir: Rails.root)
      expect(status.success?).to be(false)
      expect(errors).to match(message)
    end
  end
end
