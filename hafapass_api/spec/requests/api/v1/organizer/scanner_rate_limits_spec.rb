# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Production scanner rate-limit contract", type: :request do
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

  it "allows six verified gate staff behind one NAT to send 600 scans without the generic 300 budget" do
    users = create_list(:user, 6)
    users.each_with_index do |user, index|
      allow(ClerkAuthenticator).to receive(:verify).with("gate-#{index}").and_return({ "sub" => user.clerk_id })
    end
    users.each_index do |index|
      100.times { expect(hit(token: "gate-#{index}").first).to eq(204) }
    end
    # Other paths still hit their original budget under the same IP.
    300.times { expect(hit(path: "/api/v1/events", method: "GET").first).to eq(204) }
    expect(hit(path: "/api/v1/events", method: "GET").first).to eq(429)
  end

  it "binds the user budget to verified identity across changing IPs/device IDs" do
    user = create(:user)
    allow(ClerkAuthenticator).to receive(:verify).with("real").and_return({ "sub" => user.clerk_id })
    180.times { |i| expect(hit(token: "real", ip: "198.51.100.#{i % 100}").first).to eq(204) }
    status, headers, body = hit(token: "real", path: path.sub("456", "999"), ip: "198.51.100.254")
    expect(status).to eq(429)
    expect(headers.fetch("Retry-After").to_i).to be_between(1, 60)
    expect(JSON.parse(body.join)).to include("error" => "Rate limit exceeded")
  end

  it "limits unauthenticated, invalid-token and nonexistent-user traffic despite forged user headers" do
    allow(ClerkAuthenticator).to receive(:verify).with("ghost").and_return({ "sub" => "nonexistent" })
    60.times do |i|
      expect(hit(token: [nil, "forged", "ghost"][i % 3], "HTTP_X_USER_ID" => i.to_s).first).to eq(204)
    end
    expect(hit(token: "forged", "HTTP_X_USER_ID" => "admin").first).to eq(429)
  end

  it "bounds shared-NAT total traffic and manifest downloads independently" do
    user = create(:user)
    allow(ClerkAuthenticator).to receive(:verify).with("real").and_return({ "sub" => user.clerk_id })
    manifest = path.sub("/sync", "/manifest.json/")
    12.times { expect(hit(token: "real", path: manifest, method: "GET").first).to eq(204) }
    expect(hit(token: "real", path: manifest, method: "GET").first).to eq(429)
    expect(Rack::Attack.throttles.fetch("scanner/ip").limit).to eq(2400)
    # Real ceiling is enforced even when identity varies; unknown requests also
    # count toward it, without needing thousands of database/auth operations.
    throttle = Rack::Attack.throttles.fetch("scanner/ip")
    request = Rack::Attack::Request.new(Rack::MockRequest.env_for(path, method: "POST", "REMOTE_ADDR" => "203.0.113.99"))
    2400.times { expect(throttle.matched_by?(request)).to be_falsey }
    expect(throttle.matched_by?(request)).to be_truthy
  end
end
