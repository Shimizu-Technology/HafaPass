require "rails_helper"

RSpec.describe "Admin pilot validation reviews", type: :request do
  let(:submitter) { create(:user, :admin) }
  let(:approver) { create(:user, :admin) }
  let(:event) do
    profile = create(:organizer_profile, :payout_ready)
    create(:event, organizer_profile: profile, organization: profile.organization).tap do |record|
      create(:ticket_type, event: record)
    end
  end
  let!(:readiness) { create_pilot_readiness_approval(event: event) }
  let(:payload) do
    attributes = valid_pilot_validation_attributes(event: event)
    attributes.transform_values { |value| value.respond_to?(:iso8601) ? value.iso8601 : value }
  end

  it "shows candidate-bound Gate F requirements" do
    get "/api/v1/admin/events/#{event.id}/pilot_validation", headers: auth_headers(submitter)

    expect(response).to have_http_status(:ok)
    validation = response.parsed_body.fetch("pilot_validation")
    expect(validation).to include("prerequisite_ready" => true, "approved" => false)
    expect(validation.fetch("required_devices")).to include("ios_safari", "android_chrome")
    expect(validation.fetch("required_accessibility_checks")).to include("no_medical_proof_request")
  end

  it "keeps the admin event list lightweight" do
    expect(PilotReadiness).not_to receive(:event_state_digest)

    get "/api/v1/admin/events", headers: auth_headers(submitter)

    expect(response).to have_http_status(:ok)
    summary = response.parsed_body.fetch("events").first.fetch("pilot_validation")
    expect(summary).to include("approval_recorded" => false, "pending_submission" => nil)
  end

  it "submits and independently approves the full validation matrix" do
    post "/api/v1/admin/events/#{event.id}/pilot_validation_reviews", params: payload,
      headers: auth_headers(submitter)

    expect(response).to have_http_status(:created)
    submission_id = response.parsed_body.fetch("id")
    expect(response.parsed_body).to include(
      "pilot_readiness_review_id" => readiness.id,
      "application_revision" => PilotReadiness.application_revision
    )

    post "/api/v1/admin/pilot_validation_reviews/#{submission_id}/approve", headers: auth_headers(approver)

    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to include("decision" => "approval", "active" => true)
  end

  it "returns a clear bad request for malformed structured evidence" do
    post "/api/v1/admin/events/#{event.id}/pilot_validation_reviews",
      params: payload.merge(load_results: "looks good"), headers: auth_headers(submitter)

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body.fetch("error")).to eq("load_results must be an object")
    expect(PilotValidationReview.count).to eq(0)
  end

  it "does not expose tester and reviewer references outside admin authorization" do
    organizer = create(:user, :organizer)

    get "/api/v1/admin/events/#{event.id}/pilot_validation", headers: auth_headers(organizer)

    expect(response).to have_http_status(:forbidden)
    expect(response.body).not_to include("private-qa")
  end
end
