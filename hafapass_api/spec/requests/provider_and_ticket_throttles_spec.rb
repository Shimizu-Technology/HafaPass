require "rails_helper"

RSpec.describe "Provider webhook and ticket page throttles", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  # Keep each burst inside one fixed throttle window.
  around do |example|
    freeze_time { example.run }
  end

  let(:visitor_budget) { Rack::Attack.throttles.fetch("req/ip").limit }

  def stripe_delivery
    post "/webhooks/stripe", params: "{}", headers: { "CONTENT_TYPE" => "application/json", "Stripe-Signature" => "t=1,v1=bad" }
  end

  it "keeps provider webhooks out of the visitor budget and limits them separately" do
    expect(Rack::Attack.throttles.fetch("webhooks/ip").limit).to eq(600)
    (visitor_budget + 1).times { stripe_delivery }
    expect(response).not_to have_http_status(:too_many_requests)
    post "/webhooks/resend", params: "{}", headers: { "CONTENT_TYPE" => "application/json" }
    expect(response).not_to have_http_status(:too_many_requests)

    # The visitor budget for the same address is untouched.
    get "/api/v1/health"
    expect(response).to have_http_status(:ok)

    (600 - visitor_budget - 2).times { stripe_delivery }
    expect(response).not_to have_http_status(:too_many_requests)
    stripe_delivery
    expect(response).to have_http_status(:too_many_requests)
    expect(response.parsed_body).to include("error" => "Rate limit exceeded")
  end

  it "lets a crowd on one address open many ticket pages, limiting each ticket instead" do
    (visitor_budget + 5).times do |index|
      get "/api/v1/tickets/HP-THROTTLE-#{index}"
      expect(response).not_to have_http_status(:too_many_requests)
    end
    get "/api/v1/health"
    expect(response).to have_http_status(:ok)

    59.times { get "/api/v1/tickets/HP-THROTTLE-0" }
    expect(response).not_to have_http_status(:too_many_requests)
    get "/api/v1/tickets/HP-THROTTLE-0"
    expect(response).to have_http_status(:too_many_requests)
    get "/api/v1/tickets/HP-THROTTLE-1"
    expect(response).not_to have_http_status(:too_many_requests)
  end

  it "counts trailing-slash, format and percent-encoded spellings of one ticket in the same bucket" do
    spellings = %w[HP-THROTTLE-0 HP-THROTTLE-0/ HP-THROTTLE-0// HP-THROTTLE-0.json HP-THROTTLE-0.json/ HP-THROTTLE-%30]
    60.times { |index| get "/api/v1/tickets/#{spellings[index % spellings.size]}" }
    expect(response).not_to have_http_status(:too_many_requests)
    spellings.each do |spelling|
      get "/api/v1/tickets/#{spelling}"
      expect(response).to have_http_status(:too_many_requests), spelling
    end
    get "/api/v1/tickets/HP-THROTTLE-1.json"
    expect(response).not_to have_http_status(:too_many_requests)
  end

  it "issues display credentials that never contain a dot" do
    ticket = create(:ticket)
    5.times do
      expect(ticket.display_credential).to match(/\A[A-Za-z0-9_-]+--[0-9a-f]+\z/)
      ticket.revoke_display_credential!
    end
  end

  it "still counts ticket downloads and other ticket actions in the visitor budget" do
    visitor_budget.times { get "/api/v1/tickets/HP-THROTTLE-0/download" }
    get "/api/v1/tickets/HP-THROTTLE-0/download"
    expect(response).to have_http_status(:too_many_requests)
  end

  it "caps ticket page views from one address at 600 a minute across tickets" do
    expect(Rack::Attack.throttles.fetch("ticket-view/ip").limit).to eq(600)
    600.times { |index| get "/api/v1/tickets/HP-THROTTLE-IP-#{index}" }
    expect(response).not_to have_http_status(:too_many_requests)
    get "/api/v1/tickets/HP-THROTTLE-IP-next"
    expect(response).to have_http_status(:too_many_requests)
  end

  it "only exempts webhook deliveries (POST) from the visitor budget" do
    visitor_budget.times { get "/webhooks/stripe" }
    get "/webhooks/stripe"
    expect(response).to have_http_status(:too_many_requests)
  end

  it "logs which header supplied the throttle address once per process, without the address" do
    logged = Rails.logger
    messages = []
    allow(logged).to receive(:info).and_wrap_original { |original, *args, &block| messages << args.first; original.call(*args, &block) }
    Operations::ClientIpSource::LOGGED.make_false

    get "/api/v1/health", headers: { "X-Forwarded-For" => "203.0.113.5", "CF-Connecting-IP" => "203.0.113.5" }
    get "/api/v1/health", headers: { "X-Forwarded-For" => "203.0.113.6" }

    entries = messages.grep(String).select { |message| message.include?("rack_attack_client_ip_source") }
    expect(entries.size).to eq(1)
    expect(JSON.parse(entries.first)).to include("source" => "x_forwarded_for", "cf_connecting_ip" => "matches")
    expect(entries.first).not_to include("203.0.113")
  end
end

RSpec.describe Operations::ClientIpSource do
  def describe_env(env)
    described_class.describe(Rack::Request.new(Rack::MockRequest.env_for("/", env)))
  end

  it "reports when Rack chose a CDN edge address instead of the visitor" do
    result = describe_env("REMOTE_ADDR" => "10.0.0.1", "HTTP_X_FORWARDED_FOR" => "203.0.113.5, 198.51.100.7",
      "HTTP_CF_CONNECTING_IP" => "203.0.113.5")
    expect(result).to eq(source: "x_forwarded_for", forwarded_hops: 2, position_from_right: 0,
      cf_connecting_ip: "differs", true_client_ip: "absent")
  end

  it "reports a direct connection" do
    expect(describe_env("REMOTE_ADDR" => "198.51.100.7")).to include(source: "remote_addr", forwarded_hops: 0)
  end
end
