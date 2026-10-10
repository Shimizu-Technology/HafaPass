# frozen_string_literal: true

require "rails_helper"
require "yaml"
require "open3"
require "tmpdir"

RSpec.describe "Future separated Sidekiq deployment ownership contract" do
  let(:blueprint) { YAML.safe_load(Rails.root.join("../render.sidekiq.yaml").read) }
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
      expect(service.fetch("dockerCommand")).not_to match(/sh -c|export|[;'"$]/)
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

RSpec.describe "Render direct command execution" do
  def run_direct_command(command, environment: {})
    Dir.mktmpdir("hafapass-render-command") do |directory|
      # The real release executable applies its database guard and execs this
      # stub. Other commands reach their intended bundle target without starting
      # a server/worker or contacting a database/provider.
      File.write(File.join(directory, "bundle"), <<~RUBY)
        #!#{RbConfig.ruby}
        require "json"
        require "active_support/core_ext/object/blank"
        require #{Rails.root.join("app/services/application_revision").to_s.inspect}
        puts JSON.generate(arguments: ARGV, revision: ApplicationRevision.current,
          configured: ApplicationRevision.configured?, database: ENV["DATABASE_URL"],
          staging_database: ENV["STAGING_DATABASE_URL"])
      RUBY
      File.chmod(0o755, File.join(directory, "bundle"))
      env = { "PATH" => "#{directory}:#{ENV.fetch('PATH')}", "RAILS_ENV" => "staging", "RUBYOPT" => nil,
        "RENDER_GIT_COMMIT" => "a" * 40, "GIT_SHA" => "b" * 40, "COMMIT_REF" => "c" * 40,
        "DATABASE_URL" => "postgresql://ep-fixture-pooler.example.neon.tech/hafapass_staging",
        "STAGING_DATABASE_URL" => "postgresql://ep-fixture-pooler.example.neon.tech/hafapass_staging",
        "DATABASE_MIGRATION_URL" => "postgresql://ep-fixture.example.neon.tech/hafapass_staging" }.merge(environment)
      Open3.capture3(env, *command.split, chdir: Rails.root)
    end
  end

  %w[render.yaml render.sidekiq.yaml].each do |filename|
    it "launches #{filename} targets directly and uses the real guarded release executable" do
      applications = YAML.safe_load(Rails.root.join("../#{filename}").read).fetch("services")
        .select { |service| %w[web worker].include?(service["type"]) }
      expected_arguments = { "hafapass-api" => %w[exec puma -C config/puma.rb],
        "hafapass-worker" => %w[exec sidekiq -C config/sidekiq.yml],
        "hafapass-commerce-clock" => %w[exec rails runner script/commerce_clock.rb] }
      applications.each do |service|
        output, error, status = run_direct_command(service.fetch("dockerCommand"))
        expect(status.success?).to be(true), error
        expect(JSON.parse(output)).to include("arguments" => expected_arguments.fetch(service.fetch("name")),
          "revision" => "a" * 40, "configured" => true)
      end
      command = applications.find { |service| service["preDeployCommand"] }.fetch("preDeployCommand")
      output, error, status = run_direct_command(command)
      expect(status.success?).to be(true), error
      expect(JSON.parse(output)).to include("arguments" => %w[exec rails db:migrate], "revision" => "a" * 40,
        "database" => "postgresql://ep-fixture.example.neon.tech/hafapass_staging",
        "staging_database" => "postgresql://ep-fixture.example.neon.tech/hafapass_staging")
      output, error, status = run_direct_command(command,
        environment: { "DATABASE_MIGRATION_URL" => "postgresql://ep-other.example.neon.tech/hafapass_staging" })
      expect(status.exitstatus).to eq(1)
      expect(error).to include("configured application endpoint and database")
      expect(output).to be_empty
    end
  end
end

RSpec.describe "Initial single-service deployment contract" do
  it "selects only the existing $7 API with durable embedded staging and no additional billed services" do
    blueprint = YAML.safe_load(Rails.root.join("../render.yaml").read)
    expect(blueprint.fetch("services").map { |service| service["name"] }).to eq(["hafapass-api"])
    service = blueprint.fetch("services").first
    expect(service).to include("plan" => "0.5c-512mb", "runtime" => "docker", "healthCheckPath" => "/up")
    env = blueprint.fetch("envVarGroups").first.fetch("envVars").to_h { |entry| [entry["key"], entry["value"]] }
    expect(env).to include("RAILS_ENV" => "staging", "HAFAPASS_RUNTIME" => "embedded", "DB_POOL" => "10")
    expect(service.fetch("envVars").none? { |entry| entry["key"] == "REDIS_URL" }).to be(true)
  end
end
