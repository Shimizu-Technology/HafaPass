require "rails_helper"

RSpec.describe "Admin event-day rehearsal reviews", type: :request do
  let(:submitter) { create(:user, :admin) }
  let(:approver) { create(:user, :admin) }
  let(:event) do
    profile = create(:organizer_profile, :payout_ready)
    create(:event, organizer_profile: profile, organization: profile.organization).tap do |record|
      create(:ticket_type, event: record)
    end
  end
  let!(:validation) { create_pilot_validation_approval(event: event) }
  let(:payload) do
    valid_event_day_rehearsal_attributes(event: event).transform_values do |value|
      value.respond_to?(:iso8601) ? value.iso8601 : value
    end
  end

  it "shows candidate-bound Gate G requirements" do
    get "/api/v1/admin/events/#{event.id}/event_day_rehearsal", headers: auth_headers(submitter)

    expect(response).to have_http_status(:ok)
    status = response.parsed_body.fetch("event_day_rehearsal")
    expect(status).to include("prerequisite_ready" => true, "approved" => false, "minimum_physical_devices" => 3)
    expect(status.fetch("required_incident_drills")).to include("venue_network_loss", "worker_failure")
  end

  it "keeps the admin event list lightweight" do
    expect(PilotReadiness).not_to receive(:event_state_digest)

    get "/api/v1/admin/events", headers: auth_headers(submitter)

    expect(response).to have_http_status(:ok)
    summary = response.parsed_body.fetch("events").first.fetch("event_day_rehearsal")
    expect(summary).to include("approval_recorded" => false, "pending_submission" => nil)
  end

  it "submits and independently approves the complete rehearsal record" do
    post "/api/v1/admin/events/#{event.id}/event_day_rehearsal_reviews", params: payload,
      headers: auth_headers(submitter)

    expect(response).to have_http_status(:created)
    submission_id = response.parsed_body.fetch("id")
    expect(response.parsed_body).to include("pilot_validation_review_id" => validation.id)

    post "/api/v1/admin/event_day_rehearsal_reviews/#{submission_id}/approve", headers: auth_headers(approver)

    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to include("decision" => "approval", "active" => true)
  end

  it "rejects malformed structured rehearsal evidence without a server error" do
    post "/api/v1/admin/events/#{event.id}/event_day_rehearsal_reviews",
      params: payload.merge(device_results: "three devices passed"), headers: auth_headers(submitter)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("three physical devices")
    expect(EventDayRehearsalReview.count).to eq(0)
  end

  it "does not expose rehearsal evidence to an organizer through admin routes" do
    organizer = create(:user, :organizer)

    get "/api/v1/admin/events/#{event.id}/event_day_rehearsal", headers: auth_headers(organizer)

    expect(response).to have_http_status(:forbidden)
    expect(response.body).not_to include("private-rehearsal")
  end
end
