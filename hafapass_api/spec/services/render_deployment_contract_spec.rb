# frozen_string_literal: true

require "rails_helper"
require "yaml"

RSpec.describe "Render deployment ownership contract" do
  let(:blueprint) { YAML.safe_load(Rails.root.join("../render.yaml").read) }
  let(:services) { blueprint.fetch("services") }
  let(:applications) { services.select { |service| %w[web worker].include?(service["type"]) } }
  let(:web) { services.find { |service| service["name"] == "hafapass-api" } }

  it "keeps one queue executor, one singleton clock, and one release migration owner" do
    expect(applications.count { |service| service["dockerCommand"].include?("bundle exec sidekiq") }).to eq(1)
    clocks = applications.select { |service| service["dockerCommand"].include?("script/commerce_clock.rb") }
    expect(clocks.size).to eq(1)
    expect(clocks.first.fetch("numInstances")).to eq(1)
    expect(applications.select { |service| service["preDeployCommand"] }.map { |service| service["name"] }).to eq(["hafapass-api"])
    expect(web.fetch("preDeployCommand")).to include("bin/release-migrate")
    expect(applications.none? { |service| service["dockerCommand"].match?(/db:migrate|release-migrate/) }).to be(true)
  end

  it "preserves the existing API tier and coordinates explicit release identities on the original topology" do
    expect(web).not_to have_key("plan")
    expect(web.fetch("healthCheckPath")).to eq("/up")
    applications.each do |service|
      expect(service).to include("region" => "singapore", "runtime" => "docker", "rootDir" => "hafapass_api",
        "branch" => "main", "autoDeployTrigger" => "off")
      expect(service.fetch("dockerCommand")).to include('export GIT_SHA="$RENDER_GIT_COMMIT"')
    end
    expect(blueprint.dig("previews", "generation")).to eq("off")
  end

  it "uses a durable dedicated queue without an externally open access list" do
    queue = services.find { |service| service["type"] == "keyvalue" }
    expect(queue).to include("plan" => "256mb", "region" => "singapore", "maxmemoryPolicy" => "noeviction",
      "persistenceMode" => "journal-snapshot", "ipAllowList" => [])
    applications.each do |service|
      redis = service.fetch("envVars").find { |variable| variable["key"] == "REDIS_URL" }
      expect(redis.fetch("fromService")).to include("name" => queue.fetch("name"), "property" => "connectionString")
    end
  end

  it "keeps migration credentials off worker and clock and never hardcodes application secrets" do
    expect(web.fetch("envVars").find { |variable| variable["key"] == "DATABASE_MIGRATION_URL" }).to include("sync" => false)
    (applications - [web]).each do |service|
      expect(service.fetch("envVars").none? { |variable| variable["key"] == "DATABASE_MIGRATION_URL" }).to be(true)
    end
    %w[DATABASE_URL SECRET_KEY_BASE CLERK_SECRET_KEY AWS_SECRET_ACCESS_KEY RESEND_API_KEY ADMISSION_MANIFEST_PRIVATE_KEY_PEM].each do |key|
      variable = web.fetch("envVars").find { |entry| entry["key"] == key }
      expect(variable).to include("sync" => false)
      expect(variable).not_to have_key("value")
    end
  end
end
