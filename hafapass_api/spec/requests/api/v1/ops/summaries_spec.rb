# frozen_string_literal: true

require "rails_helper"

RSpec.describe "GET /api/v1/ops/summary", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:token) { "ops-test-token-#{'a' * 40}" }
  let(:other_token) { "ops-test-token-#{'b' * 40}" }
  let(:headers) { { "Authorization" => "Bearer #{token}" } }

  around do |example|
    original = ENV["OPS_SUMMARY_TOKEN"]
    ENV["OPS_SUMMARY_TOKEN"] = token
    freeze_time { example.run }
  ensure
    original.nil? ? ENV.delete("OPS_SUMMARY_TOKEN") : ENV["OPS_SUMMARY_TOKEN"] = original
  end

  before { allow(Rails.logger).to receive(:info).and_call_original }

  it "returns the aggregate summary for a valid token, uncached" do
    get "/api/v1/ops/summary", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.parsed_body).to include("guam_date", "sales", "events", "on_sale", "health")
  end

  it "answers 401 without a token, with a wrong token, with a malformed header and with a query-string token" do
    get "/api/v1/ops/summary"
    expect(response).to have_http_status(:unauthorized)
    get "/api/v1/ops/summary", headers: { "Authorization" => "Bearer #{other_token}" }
    expect(response).to have_http_status(:unauthorized)
    get "/api/v1/ops/summary", headers: { "Authorization" => token }
    expect(response).to have_http_status(:unauthorized)
    get "/api/v1/ops/summary", params: { token: token }
    expect(response).to have_http_status(:unauthorized)
    expect(response.body).not_to include("guam_date")
  end

  it "does not accept a user session in place of the token" do
    admin = create(:user, :admin)
    get "/api/v1/ops/summary", headers: auth_headers(admin)
    expect(response).to have_http_status(:unauthorized)
  end

  it "is not found when no usable token is configured, including a too-short one" do
    ENV["OPS_SUMMARY_TOKEN"] = nil
    get "/api/v1/ops/summary", headers: headers
    expect(response).to have_http_status(:not_found)
    ENV["OPS_SUMMARY_TOKEN"] = "short-token"
    get "/api/v1/ops/summary", headers: { "Authorization" => "Bearer short-token" }
    expect(response).to have_http_status(:not_found)
  end

  it "accepts either token while one is being rotated" do
    ENV["OPS_SUMMARY_TOKEN"] = "#{other_token}, #{token}"
    get "/api/v1/ops/summary", headers: headers
    expect(response).to have_http_status(:ok)
    get "/api/v1/ops/summary", headers: { "Authorization" => "Bearer #{other_token}" }
    expect(response).to have_http_status(:ok)
  end

  it "compares digests in constant time" do
    allow(ActiveSupport::SecurityUtils).to receive(:secure_compare).and_call_original
    get "/api/v1/ops/summary", headers: { "Authorization" => "Bearer #{other_token}" }
    expect(ActiveSupport::SecurityUtils).to have_received(:secure_compare).with(Digest::SHA256.digest(token), Digest::SHA256.digest(other_token))
  end

  it "takes a date, and rejects a bad or future one with 422" do
    get "/api/v1/ops/summary", params: { date: "today" }, headers: headers
    expect(response.parsed_body["window"]["partial"]).to be(true)
    get "/api/v1/ops/summary", params: { date: "nope" }, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    get "/api/v1/ops/summary", params: { date: (Time.current + 3.days).to_date.iso8601 }, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "writes one audit log line per request with the outcome, never the token" do
    lines = []
    allow(Rails.logger).to receive(:info) { |line| lines << line.to_s }
    get "/api/v1/ops/summary", headers: headers
    get "/api/v1/ops/summary", headers: { "Authorization" => "Bearer #{other_token}" }
    entries = lines.select { |line| line.include?("ops_summary_read") }.map { |line| JSON.parse(line) }
    expect(entries.map { |entry| entry["outcome"] }).to eq(%w[ok unauthorized])
    expect(entries.first).to include("request_id", "date")
    expect(lines.join).not_to include(token, other_token)
  end

  it "is limited to 10 requests a minute per address, valid or not" do
    expect(Rack::Attack.throttles.fetch("ops-summary/ip").limit).to eq(10)
    10.times { get "/api/v1/ops/summary", headers: { "Authorization" => "Bearer #{other_token}" } }
    expect(response).to have_http_status(:unauthorized)
    get "/api/v1/ops/summary", headers: headers
    expect(response).to have_http_status(:too_many_requests)
  end
end
