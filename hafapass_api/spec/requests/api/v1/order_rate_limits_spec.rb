# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Order creation rate-limit contract", type: :request do
  # Drive the installed middleware/config; the stub app avoids real checkouts.
  let(:app) { Rack::Attack.new(->(_env) { [201, {}, []] }) }

  def place_order(email:, ip: "203.0.113.90", headers: {})
    env = Rack::MockRequest.env_for("/api/v1/orders", { method: "POST", "REMOTE_ADDR" => ip,
      "CONTENT_TYPE" => "application/json", input: { buyer_email: email }.to_json }.merge(headers))
    app.call(env).first
  end

  it "throttles by the Cloudflare client address, not the shared edge address" do
    edge = "172.70.1.1"
    30.times do |index|
      expect(place_order(email: "cf-#{index}@example.com", ip: edge, headers: { "HTTP_CF_CONNECTING_IP" => "203.0.113.40" })).to eq(201)
    end
    expect(place_order(email: "cf-31@example.com", ip: edge, headers: { "HTTP_CF_CONNECTING_IP" => "203.0.113.40" })).to eq(429)
    expect(place_order(email: "cf-32@example.com", ip: edge, headers: { "HTTP_CF_CONNECTING_IP" => "203.0.113.41" })).to eq(201)
  end

  it "allows 30 orders a minute from one shared network address, then throttles" do
    30.times { |index| expect(place_order(email: "guest-#{index}@example.com")).to eq(201) }
    expect(place_order(email: "guest-31@example.com")).to eq(429)
    expect(place_order(email: "guest-31@example.com", ip: "203.0.113.91")).to eq(201)
  end

  it "throttles one buyer email at 5 orders a minute across addresses, ignoring case and spacing" do
    variants = ["buyer@example.com", " BUYER@example.com", "Buyer@Example.com ", "buyer@EXAMPLE.com", "buyer@example.com"]
    variants.each_with_index { |email, index| expect(place_order(email: email, ip: "198.51.100.#{index}")).to eq(201) }
    expect(place_order(email: "  buyer@example.com", ip: "198.51.100.200")).to eq(429)
    expect(place_order(email: "other@example.com", ip: "198.51.100.201")).to eq(201)
  end

  it "no longer has the legacy unscoped check-in route or throttle" do
    expect(Rack::Attack.throttles.keys).not_to include("checkin/ip")
    expect { Rails.application.routes.recognize_path("/api/v1/check_in/abc", method: :post) }
      .to raise_error(ActionController::RoutingError)
  end
end
