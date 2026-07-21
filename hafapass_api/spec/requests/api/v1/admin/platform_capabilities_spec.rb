require "rails_helper"

RSpec.describe "Admin platform capabilities", type: :request do
  let(:submitter) { create(:user, :admin) }
  let(:approver) { create(:user, :admin) }
  let(:controls) { PlatformCapabilities.required_controls("policy_register").index_with { true } }
  let(:payload) do
    {
      evidence_reference: "controlled/legal/policy-register-17",
      evidence_digest: "d" * 64,
      controls: controls,
      effective_at: 1.minute.ago.iso8601,
      expires_at: 90.days.from_now.iso8601
    }
  end

  it "lists redacted configuration and approval state" do
    get "/api/v1/admin/platform_capabilities", headers: auth_headers(submitter)

    expect(response).to have_http_status(:ok)
    policy = response.parsed_body.fetch("capabilities").find { |item| item["capability"] == "policy_register" }
    expect(policy).to include("configured" => true, "approved" => false, "enabled" => false)
    expect(policy.fetch("required_controls")).to include("counsel_approved")
    expect(response.body).not_to include("RESEND_API_KEY", "STRIPE_LIVE_SECRET_KEY")
  end

  it "submits and independently approves capability evidence" do
    post "/api/v1/admin/platform_capabilities/policy_register/reviews", params: payload,
      headers: auth_headers(submitter)

    expect(response).to have_http_status(:created)
    submission_id = response.parsed_body.fetch("id")

    patch "/api/v1/admin/platform_capability_reviews/#{submission_id}/approve", headers: auth_headers(approver)

    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to include("decision" => "approval", "active" => true)
  end

  it "does not allow credentials or unknown capability names to bypass evidence" do
    post "/api/v1/admin/platform_capabilities/not-real/reviews", params: payload,
      headers: auth_headers(submitter)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(PlatformCapabilityReview.count).to eq(0)
  end
end
