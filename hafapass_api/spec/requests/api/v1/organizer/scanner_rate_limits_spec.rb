# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Production scanner rate-limit contract", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  # Drive the installed middleware/config, not isolated throttle predicates.
  # The response app avoids 600 real check-ins; verification uses the same
  # ClerkAuthenticator entry point as production, with synthetic signed IDs.
  let(:app) { Rack::Attack.new(->(_env) { [204, {}, []] }) }
  let(:path) { "/api/v1/organizer/events/123/scanner_devices/456/sync" }

  def hit(token: nil, path: self.path, method: "POST", ip: "203.0.113.56", **headers)
    env = Rack::MockRequest.env_for(path, method: method, "REMOTE_ADDR" => ip, **headers)
    env["HTTP_AUTHORIZATION"] = "Bearer #{token}" if token
    app.call(env)
  end

  before do
    # Exercise the production atomic SQL counter on this suite's owned DB.
    Rack::Attack.cache.store = Operations::PostgresThrottleStore.new
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
    allow(ClerkAuthenticator).to receive(:verify).and_return(nil)
  end

  it "allows six verified gate staff behind one NAT to send 600 scans without consuming the generic req/ip budget" do
    original_req_limit = ENV["RACK_ATTACK_REQ_PER_IP_5M"]
    ENV["RACK_ATTACK_REQ_PER_IP_5M"] = "50"

    users = create_list(:user, 6)
    users.each_with_index do |user, index|
      allow(ClerkAuthenticator).to receive(:verify).with("gate-#{index}").and_return({ "sub" => user.clerk_id })
    end
    # Keep every hit in one throttle window; a boundary mid-loop resets counts.
    freeze_time do
      users.each_index do |index|
        100.times { expect(hit(token: "gate-#{index}").first).to eq(204) }
      end
      # Other paths still hit their configured req/ip budget under the same IP.
      50.times { expect(hit(path: "/api/v1/events", method: "GET").first).to eq(204) }
      expect(hit(path: "/api/v1/events", method: "GET").first).to eq(429)
    end
  ensure
    original_req_limit.nil? ? ENV.delete("RACK_ATTACK_REQ_PER_IP_5M") : ENV["RACK_ATTACK_REQ_PER_IP_5M"] = original_req_limit
  end

  it "binds the user budget to verified identity across changing IPs/device IDs" do
    user = create(:user)
    allow(ClerkAuthenticator).to receive(:verify).with("real").and_return({ "sub" => user.clerk_id })
    # Keep every hit in one throttle window; a boundary mid-loop resets counts.
    status, headers, body = freeze_time do
      180.times { |i| expect(hit(token: "real", ip: "198.51.100.#{i % 100}").first).to eq(204) }
      hit(token: "real", path: path.sub("456", "999"), ip: "198.51.100.254")
    end
    expect(status).to eq(429)
    expect(headers.fetch("Retry-After").to_i).to be_between(1, 60)
    expect(JSON.parse(body.join)).to include("error" => "Rate limit exceeded")
  end

  it "limits unauthenticated, invalid-token and nonexistent-user traffic despite forged user headers" do
    allow(ClerkAuthenticator).to receive(:verify).with("ghost").and_return({ "sub" => "nonexistent" })
    freeze_time do
      60.times do |i|
        expect(hit(token: [nil, "forged", "ghost"][i % 3], "HTTP_X_USER_ID" => i.to_s).first).to eq(204)
      end
      expect(hit(token: "forged", "HTTP_X_USER_ID" => "admin").first).to eq(429)
    end
  end

  it "bounds shared-NAT total traffic and manifest downloads independently" do
    user = create(:user)
    allow(ClerkAuthenticator).to receive(:verify).with("real").and_return({ "sub" => user.clerk_id })
    manifest = path.sub("/sync", "/manifest.json/")
    freeze_time do
      12.times { expect(hit(token: "real", path: manifest, method: "GET").first).to eq(204) }
      expect(hit(token: "real", path: manifest, method: "GET").first).to eq(429)
    end
    expect(Rack::Attack.throttles.fetch("scanner/ip").limit).to eq(2400)
    # Real ceiling is enforced even when identity varies; unknown requests also
    # count toward it, without needing thousands of database/auth operations.
    throttle = Rack::Attack.throttles.fetch("scanner/ip")
    request = Rack::Attack::Request.new(Rack::MockRequest.env_for(path, method: "POST", "REMOTE_ADDR" => "203.0.113.99"))
    # Keep all hits in one throttle window; a minute boundary mid-loop resets the count.
    freeze_time do
      2400.times { expect(throttle.matched_by?(request)).to be_falsey }
      expect(throttle.matched_by?(request)).to be_truthy
    end
  end
end
