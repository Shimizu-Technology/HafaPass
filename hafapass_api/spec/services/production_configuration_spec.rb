# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProductionConfiguration do
  REQUIRED_ENV = {
    "DATABASE_URL" => "configured",
    "REDIS_URL" => "configured",
    "CLERK_SECRET_KEY" => "configured",
    "CLERK_PUBLISHABLE_KEY" => "configured",
    "FRONTEND_URL" => "https://hafapass.example/",
    "PUBLIC_WEB_URL" => "https://hafapass.example/",
    "ALLOWED_ORIGINS" => "https://hafapass.example/,https://admin.hafapass.example",
    "GIT_SHA" => "a" * 40,
    "SENTRY_DSN" => "configured",
    "RESEND_API_KEY" => "configured",
    "RESEND_WEBHOOK_SECRET" => "configured",
    "MAILER_FROM_EMAIL" => "tickets@hafapass.example",
    "PROVIDER_CONFIGURATION_REVISION" => "2026-07-pilot-1",
    "AWS_ACCESS_KEY_ID" => "configured",
    "AWS_SECRET_ACCESS_KEY" => "configured",
    "AWS_BUCKET" => "configured",
    "AWS_REGION" => "configured",
    "ADMISSION_MANIFEST_PRIVATE_KEY_PEM" => "configured",
    "ENABLE_FIRST_USER_ADMIN_BOOTSTRAP" => "false"
  }.freeze

  around do |example|
    original = REQUIRED_ENV.keys.index_with { |key| ENV[key] }
    REQUIRED_ENV.each { |key, value| ENV[key] = value }
    example.run
  ensure
    original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  it "returns only redacted boolean checks for a complete production configuration" do
    result = described_class.call

    expect(result).to include(ready: true, status: "configured")
    expect(result[:checks].values).to all(be(true).or(be(false)))
    expect(result.to_json).not_to include("tickets@", "hafapass.example", "redis://", "a" * 40)
  end

  it "fails closed for unsafe origins, missing credentials, or first-user admin bootstrap" do
    ENV["ALLOWED_ORIGINS"] = "https://hafapass.example/tickets,http://localhost:5173,*"
    ENV.delete("SENTRY_DSN")
    ENV["ENABLE_FIRST_USER_ADMIN_BOOTSTRAP"] = "true"

    result = described_class.call

    expect(result).to include(ready: false, status: "incomplete")
    expect(result[:checks]).to include(
      public_urls: false,
      monitoring: false,
      admin_bootstrap_disabled: false
    )
  end
end
