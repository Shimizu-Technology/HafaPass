require "rails_helper"

RSpec.describe "Api::V1::OrganizerProfiles", type: :request do
  let(:user) { create(:user, :organizer) }
  let!(:profile) { create(:organizer_profile, user: user) }
  let(:headers) { auth_headers(user) }

  it "includes the image host in the profile response for configured, local, and unavailable storage" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:fetch).and_call_original
    ["synthetic-bucket", nil].each do |bucket|
      allow(ENV).to receive(:[]).with("AWS_BUCKET").and_return(bucket)
      allow(ENV).to receive(:fetch).with("AWS_BUCKET").and_return(bucket)
      get "/api/v1/organizer_profile", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["image_asset_host"]).to eq(S3Service.public_asset_host)
      expect(response.parsed_body["image_asset_host"]).to eq(bucket ? "synthetic-bucket.s3.us-west-2.amazonaws.com" : "storage.invalid")
    end
    allow(Rails.env).to receive(:local?).and_return(false)
    get "/api/v1/organizer_profile", headers: headers
    expect(response.parsed_body).to include("image_asset_host" => nil)
  end

  it "does not let an organizer assign partner status" do
    put "/api/v1/organizer_profile", params: { business_name: profile.business_name, is_ambros_partner: true }, headers: headers

    expect(response).to have_http_status(:ok)
    expect(profile.reload.is_ambros_partner).to be(false)
  end

  it "records explicit policy acceptance" do
    post "/api/v1/organizer_profile/accept_policy", headers: headers

    expect(response).to have_http_status(:ok)
    expect(profile.reload).to have_attributes(
      policy_version: PolicyRegistry.organizer_agreement[:version],
      policy_digest: PolicyRegistry.organizer_agreement[:digest]
    )
    expect(profile.policy_accepted_at).to be_present
    expect(profile).to be_policy_accepted
  end

  it "submits a complete profile for verification" do
    post "/api/v1/organizer_profile/submit_verification", headers: headers,
      params: { business_name: "Island Events", business_description: "Community events on Guam",
        verification_phone: "+1 (671) 555-1234", verification_link: "https://instagram.com/islandevents",
        verification_request_note: "Our first event is next month." }

    expect(response).to have_http_status(:ok)
    expect(profile.reload).to be_verification_status_pending
    expect(profile.verification_requested_at).to be_present
    expect(profile).to have_attributes(verification_phone: "+1 (671) 555-1234",
      verification_link: "https://instagram.com/islandevents")
  end

  it "retains the profile state when verification contact details are invalid" do
    post "/api/v1/organizer_profile/submit_verification", headers: headers,
      params: { business_name: "Island Events", business_description: "Community events",
        verification_phone: "123", verification_link: "javascript:alert(1)" }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("errors").join).to include("Verification phone", "Verification link")
    expect(profile.reload).to be_verification_status_unverified
  end
end
