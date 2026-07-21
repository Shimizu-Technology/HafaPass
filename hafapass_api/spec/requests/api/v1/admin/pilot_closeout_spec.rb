require "rails_helper"

RSpec.describe "Admin Gate J pilot closeout", type: :request do
  it "submits and independently approves the exact completed-run closeout" do
    run = create_completed_live_pilot_run
    submitter = create(:user, :admin)

    post "/api/v1/admin/events/#{run.event_id}/pilot_closeout_reviews",
      headers: auth_headers(submitter), params: valid_pilot_closeout_attributes
    expect(response).to have_http_status(:created), response.body
    submission_id = response.parsed_body.fetch("id")
    expect(response.parsed_body).to include(
      "decision" => "submission", "live_pilot_run_id" => run.id, "expansion_decision" => "hold"
    )

    post "/api/v1/admin/pilot_closeout_reviews/#{submission_id}/approve",
      headers: auth_headers(create(:user, :admin))
    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to include("decision" => "approval", "active" => true)

    get "/api/v1/admin/events/#{run.event_id}/pilot_closeout", headers: auth_headers(submitter)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("pilot_closeout", "approved")).to be(true)
    expect(response.parsed_body.dig("pilot_closeout", "latest_approval", "metric_report"))
      .to include("entry_latency_p95_ms" => 250)
  end

  it "keeps restricted Gate J evidence inaccessible to organizers" do
    run = create_completed_live_pilot_run

    get "/api/v1/admin/events/#{run.event_id}/pilot_closeout",
      headers: auth_headers(create(:user, :organizer))

    expect(response).to have_http_status(:forbidden)
  end
end
