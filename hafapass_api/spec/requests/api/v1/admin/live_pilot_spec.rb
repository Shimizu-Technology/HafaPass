require "rails_helper"

RSpec.describe "Admin Gate I live-pilot operations", type: :request do
  it "approves, starts, monitors, and safety-pauses a bounded pilot" do
    approval = create_live_pilot_approval
    event = approval.event
    admin = create(:user, :admin)

    post "/api/v1/admin/live_pilot_reviews/#{approval.id}/start", headers: auth_headers(admin)
    expect(response).to have_http_status(:created)
    run_id = response.parsed_body.fetch("id")
    expect(response.parsed_body).to include("status" => "active", "inventory_cap" => 10)

    post "/api/v1/admin/live_pilot_runs/#{run_id}/checkpoint", headers: auth_headers(admin), params: {
      evidence_reference: "restricted-pilot/checkpoint", evidence_digest: "a" * 64,
      external_metrics: safe_live_pilot_external_metrics.merge(provider_healthy: false)
    }
    expect(response).to have_http_status(:created)
    expect(response.parsed_body.fetch("breached_thresholds")).to include("provider_health")

    get "/api/v1/admin/events/#{event.id}/live_pilot", headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("live_pilot", "latest_run", "status")).to eq("paused")
  end

  it "keeps Gate I operating evidence inaccessible to organizers" do
    approval = create_live_pilot_approval

    get "/api/v1/admin/events/#{approval.event_id}/live_pilot",
      headers: auth_headers(create(:user, :organizer))

    expect(response).to have_http_status(:forbidden)
  end
end
