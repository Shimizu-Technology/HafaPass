require "rails_helper"

RSpec.describe "Admin pilot readiness reviews", type: :request do
  let(:submitter) { create(:user, :admin) }
  let(:approver) { create(:user, :admin) }
  let(:profile) { create(:organizer_profile, :payout_ready) }
  let(:event) do
    create(:event, organizer_profile: profile, organization: profile.organization).tap do |record|
      create(:ticket_type, event: record)
    end
  end
  let(:payload) do
    {
      evidence_reference: "private/pilot-readiness/#{event.id}",
      evidence_digest: "d" * 64,
      controls: PilotReadinessReview::CONTROL_KEYS.index_with(true),
      assignments: PilotReadinessReview::ASSIGNMENT_KEYS.index_with do |role|
        { name: role.humanize, contact_reference: "private-directory/#{role}" }
      end,
      effective_at: 1.minute.ago.iso8601,
      expires_at: 30.days.from_now.iso8601
    }
  end

  it "shows the event-specific readiness requirements" do
    get "/api/v1/admin/events/#{event.id}/pilot_readiness", headers: auth_headers(submitter)

    expect(response).to have_http_status(:ok)
    readiness = response.parsed_body.fetch("pilot_readiness")
    expect(readiness).to include("approved" => false, "state_current" => false)
    expect(readiness.fetch("required_controls")).to include("no_open_p0_or_p1")
    expect(readiness.fetch("required_assignments")).to include("event_commander")
  end

  it "submits and independently approves event-bound evidence" do
    post "/api/v1/admin/events/#{event.id}/pilot_readiness_reviews", params: payload,
      headers: auth_headers(submitter)

    expect(response).to have_http_status(:created)
    submission_id = response.parsed_body.fetch("id")

    post "/api/v1/admin/pilot_readiness_reviews/#{submission_id}/approve", headers: auth_headers(approver)

    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to include("decision" => "approval", "active" => true)
  end

  it "rejects incomplete controls and assignments" do
    post "/api/v1/admin/events/#{event.id}/pilot_readiness_reviews",
      params: payload.merge(controls: {}, assignments: {}), headers: auth_headers(submitter)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(PilotReadinessReview.count).to eq(0)
  end

  it "keeps named owners and private contact references behind admin authorization" do
    organizer = create(:user, :organizer)

    get "/api/v1/admin/events/#{event.id}/pilot_readiness", headers: auth_headers(organizer)

    expect(response).to have_http_status(:forbidden)
    expect(response.body).not_to include("private-directory")
  end
end
