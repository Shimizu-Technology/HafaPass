# frozen_string_literal: true

require "rails_helper"
require "open3"

RSpec.describe "Production transport and platform liveness" do
  it "boots without dependencies, accepts only its API host, and enforces HTTPS outside /up" do
    environment = {
      "RAILS_ENV" => "production", "PUBLIC_API_URL" => "https://api.hafapass.example",
      "ALLOWED_ORIGINS" => "https://hafapass.example", "SECRET_KEY_BASE" => SecureRandom.hex(64),
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
    output, errors, status = Open3.capture3(environment, "bundle", "exec", "rails", "runner", script,
      chdir: Rails.root)

    expect(status.success?).to be(true), "Production probe process failed: #{errors}"
    expect(output).to include("PROBE_STATUSES=200,301,200,403")
  end
end
