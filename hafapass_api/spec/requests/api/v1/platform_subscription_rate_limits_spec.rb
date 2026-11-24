require "rails_helper"

RSpec.describe "Platform signup throttle", type: :request do
  it "covers format suffixes and normalized slash spellings with a carrier NAT budget" do
    app = Rack::Attack.new(->(_env) { [201, {}, []] })
    paths = ["/api/v1/platform_subscriptions.html", "/api/v1/platform_subscriptions.json/", "//api/v1/platform_subscriptions"]
    limit = Rack::Attack.throttles.fetch("platform-subscription/ip").limit
    expect(limit).to eq(30)
    limit.times do |n|
      env = Rack::MockRequest.env_for(paths[n % 3], method: "POST", "REMOTE_ADDR" => "203.0.113.58")
      env["PATH_INFO"] = paths[n % 3]
      expect(app.call(env).first).to eq(201)
    end
    expect(app.call(Rack::MockRequest.env_for(paths.first, method: "POST", "REMOTE_ADDR" => "203.0.113.58")).first).to eq(429)
  end
end
