# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("script/rush_test/guard")

# The hosted rush test (docs/SATURDAY_2026-11-28_RUNBOOK.md) runs scripts from script/rush_test
# against an isolated copy of the API. These specs pin the guard that keeps them away from
# production and the capacity arithmetic the runbook states for the event-week settings.
RSpec.describe RushTest::Guard do
  let(:safe_env) do
    {
      "HAFAPASS_RUSH_TARGET" => "rush-copy.onrender.com",
      "PUBLIC_API_URL" => "https://rush-copy.onrender.com",
      "DATABASE_URL" => "postgres://user:pw@ep-rush.neon.tech/hafapass_rush_staging",
      "STAGING_DATABASE_URL" => "postgres://user:pw@ep-rush.neon.tech/hafapass_rush_staging"
    }
  end

  describe ".violations" do
    it "accepts an isolated staging copy" do
      expect(described_class.violations(env: safe_env, rails_env: "staging")).to be_empty
    end

    it "requires RAILS_ENV=staging so StageSafety applies" do
      expect(described_class.violations(env: safe_env, rails_env: "production").join).to include("RAILS_ENV must be staging")
      expect(described_class.violations(env: safe_env, rails_env: "test").join).to include("RAILS_ENV must be staging")
    end

    it "requires an explicit target that equals this service's own host" do
      expect(described_class.violations(env: safe_env.except("HAFAPASS_RUSH_TARGET"), rails_env: "staging").join).to include("HAFAPASS_RUSH_TARGET is not set")
      mismatch = safe_env.merge("HAFAPASS_RUSH_TARGET" => "another.onrender.com")
      expect(described_class.violations(env: mismatch, rails_env: "staging").join).to include("does not equal the host of PUBLIC_API_URL")
    end

    it "refuses every production host, including userinfo and trailing-dot tricks" do
      %w[hafapass-api.onrender.com hafapass.shimizu-technology.com api.hafapass.com hafapass.netlify.app].each do |host|
        env = safe_env.merge("HAFAPASS_RUSH_TARGET" => host, "PUBLIC_API_URL" => "https://#{host}")
        expect(described_class.violations(env: env, rails_env: "staging").join).to include("production host"), host
      end
      tricky = safe_env.merge("PUBLIC_API_URL" => "https://rush-copy.onrender.com@hafapass-api.onrender.com./", "HAFAPASS_RUSH_TARGET" => "hafapass-api.onrender.com")
      expect(described_class.violations(env: tricky, rails_env: "staging").join).to include("production host")
    end

    it "honours HAFAPASS_PRODUCTION_HOSTS for a future production domain" do
      env = safe_env.merge("HAFAPASS_PRODUCTION_HOSTS" => "rush-copy.onrender.com")
      expect(described_class.violations(env: env, rails_env: "staging").join).to include("production host")
    end

    it "requires a database named for both rush and staging, identical in both URL variables" do
      env = safe_env.merge("DATABASE_URL" => "postgres://u@h/hafapass_staging", "STAGING_DATABASE_URL" => "postgres://u@h/hafapass_staging")
      expect(described_class.violations(env: env, rails_env: "staging").join).to include("must contain both 'rush' and 'staging'")
      differing = safe_env.merge("STAGING_DATABASE_URL" => "postgres://u@h/other_rush_staging")
      expect(described_class.violations(env: differing, rails_env: "staging").join).to include("must be identical")
    end

    it "refuses live Stripe credentials in any slot" do
      expect(described_class.violations(env: safe_env.merge("STRIPE_LIVE_SECRET_KEY" => "x"), rails_env: "staging").join).to include("live Stripe")
      expect(described_class.violations(env: safe_env.merge("STRIPE_TEST_SECRET_KEY" => "sk_live_abc"), rails_env: "staging").join).to include("live Stripe")
    end
  end

  describe ".check_environment!" do
    it "raises Refused with every reason" do
      expect { described_class.check_environment!(env: {}, rails_env: "production") }
        .to raise_error(RushTest::Refused, /RAILS_ENV must be staging.*HAFAPASS_RUSH_TARGET is not set/m)
    end

    it "stops the seed, consistency, RTT and sampler scripts in the test environment" do
      %w[seed_fixture consistency_check neon_rtt pg_sampler].each do |script|
        expect { load Rails.root.join("script/rush_test/#{script}.rb").to_s }.to raise_error(RushTest::Refused, /RAILS_ENV must be staging/), script
      end
    end
  end

  describe ".check_no_real_data!" do
    it "passes on an empty database and on [LOAD TEST] fixtures with example.invalid buyers" do
      expect(described_class.check_no_real_data!).to be(true)
      event = create(:event, title: "[LOAD TEST] Copa Rush Free x")
      create(:order, event: event, buyer_email: "load-1@example.invalid")
      expect(described_class.check_no_real_data!).to be(true)
    end

    it "refuses a database that holds a real buyer or a real event (a copy of production data)" do
      create(:order, buyer_email: "real.buyer@example.com")
      expect { described_class.check_no_real_data! }.to raise_error(RushTest::Refused, /real buyer email.*not titled \[LOAD TEST\]/m)
    end

    it "refuses live payment mode" do
      SiteSetting.instance.update_columns(payment_mode: "live")
      expect { described_class.check_no_real_data! }.to raise_error(RushTest::Refused, /payment_mode is live/)
    end
  end
end

RSpec.describe "event-week database pool arithmetic (docs/SATURDAY_2026-11-28_RUNBOOK.md)" do
  around do |example|
    names = %w[WEB_CONCURRENCY RAILS_MAX_THREADS DB_POOL HAFAPASS_RUNTIME]
    original = names.index_with { |name| ENV[name] }
    example.run
  ensure
    original.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  it "DB_POOL=11 is exactly the per-process minimum for RAILS_MAX_THREADS=5 under the embedded runtime" do
    ENV.update("HAFAPASS_RUNTIME" => "embedded", "WEB_CONCURRENCY" => "2", "RAILS_MAX_THREADS" => "5", "DB_POOL" => "11")
    expect(RuntimeConfiguration.database_pool).to eq(11)
    expect(RuntimeConfiguration.web_threads + 6).to eq(11)

    ENV["DB_POOL"] = "10"
    expect { RuntimeConfiguration.database_pool }.to raise_error(ArgumentError, /DB_POOL must cover/)
  end

  it "yields about 16 peak and 22 ceiling connections for 2 processes (docs table), 44 during a deploy overlap" do
    ENV.update("HAFAPASS_RUNTIME" => "embedded", "WEB_CONCURRENCY" => "2", "RAILS_MAX_THREADS" => "5", "DB_POOL" => "11")
    processes = RuntimeConfiguration.web_processes
    peak = processes * RuntimeConfiguration.web_threads + 6
    ceiling = processes * RuntimeConfiguration.database_pool
    expect([peak, ceiling, ceiling * 2]).to eq([16, 22, 44])
  end

  it "uses a smaller per-process minimum when the supervisor runs in a separate worker (render.tournament.yaml)" do
    ENV.update("HAFAPASS_RUNTIME" => "solid_queue", "WEB_CONCURRENCY" => "2", "RAILS_MAX_THREADS" => "5", "DB_POOL" => "7")
    expect(RuntimeConfiguration.database_pool).to eq(7)
  end
end
