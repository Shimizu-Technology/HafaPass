# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Rack::Attack Guam CGNAT-safe defaults and ENV overrides", type: :request do
  let(:app) { Rack::Attack.new(->(_env) { [200, {}, []] }) }

  def with_env(overrides)
    originals = overrides.keys.index_with { |key| ENV[key] }
    overrides.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    originals.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end

  def call_rack(path, method: "GET", ip: "203.0.113.55", body: nil)
    opts = { method: method, "REMOTE_ADDR" => ip }
    if body
      opts["CONTENT_TYPE"] = "application/json"
      opts[:input] = body.to_json
    end
    app.call(Rack::MockRequest.env_for(path, opts)).first
  end

  describe "CGNAT-safe default limits" do
    it "configures the 6 public IP ceilings to Guam CGNAT-safe defaults when ENV is unset" do
      keys = %w[
        RACK_ATTACK_REQ_PER_IP_5M
        RACK_ATTACK_ORDERS_PER_IP_1M
        RACK_ATTACK_MARKETPLACE_LANDING_PER_IP_1M
        RACK_ATTACK_MARKETPLACE_FUNNEL_PER_IP_1M
        RACK_ATTACK_USERS_SYNC_PER_IP_1M
        RACK_ATTACK_PAYMENT_RESUME_PER_IP_1M
      ]

      with_env(keys.index_with { nil }) do
        expect(Rack::Attack.throttles.fetch("req/ip").limit.call(nil)).to eq(3000)
        expect(Rack::Attack.throttles.fetch("orders/ip").limit.call(nil)).to eq(200)
        expect(Rack::Attack.throttles.fetch("marketplace-landing/ip").limit.call(nil)).to eq(600)
        expect(Rack::Attack.throttles.fetch("marketplace-funnel/ip").limit.call(nil)).to eq(600)
        expect(Rack::Attack.throttles.fetch("users/ip").limit.call(nil)).to eq(120)
        expect(Rack::Attack.throttles.fetch("payment-resume/ip").limit.call(nil)).to eq(120)
      end
    end

    it "leaves per-email, webhook, ticket, scanner, promo, and sensitive admin throttles strictly intact" do
      expect(Rack::Attack.throttles.fetch("orders/email").limit).to eq(5)
      expect(Rack::Attack.throttles.fetch("webhooks/ip").limit).to eq(600)
      expect(Rack::Attack.throttles.fetch("ticket-view/ip").limit).to eq(600)
      expect(Rack::Attack.throttles.fetch("ticket-view/credential").limit).to eq(60)
      expect(Rack::Attack.throttles.fetch("scanner/ip").limit).to eq(2400)
      expect(Rack::Attack.throttles.fetch("scanner/user").limit).to eq(180)
      expect(Rack::Attack.throttles.fetch("tax-sensitive/ip").limit).to eq(10)
      expect(Rack::Attack.throttles.fetch("tax-sensitive/admin").limit).to eq(10)
      expect(Rack::Attack.throttles.fetch("promo/ip").limit).to eq(30)
      expect(Rack::Attack.throttles.fetch("seat-holds/ip").limit).to eq(20)
    end
  end

  describe "Rack::Attack.env_limit parsing and fallback" do
    it "parses positive integers and trims whitespace" do
      with_env("RACK_ATTACK_ORDERS_PER_IP_1M" => " 450 ") do
        expect(Rack::Attack.env_limit("RACK_ATTACK_ORDERS_PER_IP_1M", 200)).to eq(450)
      end
    end

    it "safely falls back to the default for blank, zero, negative, float, or non-numeric ENV values" do
      ["", "   ", "0", "-10", "abc", "12.5", "100px"].each do |invalid_value|
        with_env("RACK_ATTACK_ORDERS_PER_IP_1M" => invalid_value) do
          expect(Rack::Attack.env_limit("RACK_ATTACK_ORDERS_PER_IP_1M", 200)).to eq(200), "for #{invalid_value.inspect}"
        end
      end
    end
  end

  describe "ENV override enforcement" do
    it "enforces ENV overrides across all 6 public IP throttles" do
      overrides = {
        "RACK_ATTACK_REQ_PER_IP_5M" => "4",
        "RACK_ATTACK_ORDERS_PER_IP_1M" => "3",
        "RACK_ATTACK_MARKETPLACE_LANDING_PER_IP_1M" => "2",
        "RACK_ATTACK_MARKETPLACE_FUNNEL_PER_IP_1M" => "2",
        "RACK_ATTACK_USERS_SYNC_PER_IP_1M" => "2",
        "RACK_ATTACK_PAYMENT_RESUME_PER_IP_1M" => "2"
      }

      with_env(overrides) do
        # req/ip (limit 4)
        4.times { expect(call_rack("/api/v1/events", ip: "198.51.100.1")).to eq(200) }
        expect(call_rack("/api/v1/events", ip: "198.51.100.1")).to eq(429)

        # orders/ip (limit 3)
        3.times { |i| expect(call_rack("/api/v1/orders", method: "POST", ip: "198.51.100.2", body: { buyer_email: "b#{i}@example.com" })).to eq(200) }
        expect(call_rack("/api/v1/orders", method: "POST", ip: "198.51.100.2", body: { buyer_email: "b3@example.com" })).to eq(429)

        # marketplace-landing/ip (limit 2)
        2.times { expect(call_rack("/api/v1/distribution_links/FD2026", ip: "198.51.100.3")).to eq(200) }
        expect(call_rack("/api/v1/distribution_links/FD2026", ip: "198.51.100.3")).to eq(429)

        # marketplace-funnel/ip (limit 2)
        2.times { expect(call_rack("/api/v1/marketplace_funnel_events", method: "POST", ip: "198.51.100.4", body: {})).to eq(200) }
        expect(call_rack("/api/v1/marketplace_funnel_events", method: "POST", ip: "198.51.100.4", body: {})).to eq(429)

        # users/ip (limit 2)
        2.times { expect(call_rack("/api/v1/users/sync", method: "POST", ip: "198.51.100.5", body: {})).to eq(200) }
        expect(call_rack("/api/v1/users/sync", method: "POST", ip: "198.51.100.5", body: {})).to eq(429)

        # payment-resume/ip (limit 2)
        2.times { expect(call_rack("/api/v1/orders/42/payment_resume", method: "POST", ip: "198.51.100.6", body: {})).to eq(200) }
        expect(call_rack("/api/v1/orders/42/payment_resume", method: "POST", ip: "198.51.100.6", body: {})).to eq(429)
      end
    end

    it "still strictly enforces the 5/min per-email order throttle under the 200/min IP ceiling" do
      with_env("RACK_ATTACK_ORDERS_PER_IP_1M" => nil) do
        5.times do
          expect(call_rack("/api/v1/orders", method: "POST", ip: "203.0.113.88", body: { buyer_email: "repeat@example.com" })).to eq(200)
        end
        expect(call_rack("/api/v1/orders", method: "POST", ip: "203.0.113.88", body: { buyer_email: "repeat@example.com" })).to eq(429)
        # Another buyer on the same Guam CGNAT IP still succeeds
        expect(call_rack("/api/v1/orders", method: "POST", ip: "203.0.113.88", body: { buyer_email: "neighbor@example.com" })).to eq(200)
      end
    end
  end
end
