require "rails_helper"

RSpec.describe "Api::V1::OrganizerProfiles", type: :request do
  let(:user) { create(:user, :organizer) }
  let!(:profile) { create(:organizer_profile, user: user) }
  let(:headers) { auth_headers(user) }

  it "does not let an organizer assign partner status" do
    put "/api/v1/organizer_profile", params: { business_name: profile.business_name, is_ambros_partner: true }, headers: headers

    expect(response).to have_http_status(:ok)
    expect(profile.reload.is_ambros_partner).to be(false)
  end

  it "records explicit policy acceptance" do
    post "/api/v1/organizer_profile/accept_policy", headers: headers

    expect(response).to have_http_status(:ok)
    expect(profile.reload.policy_accepted_at).to be_present
  end

  it "submits a complete profile for verification" do
    post "/api/v1/organizer_profile/submit_verification", headers: headers

    expect(response).to have_http_status(:ok)
    expect(profile.reload).to be_verification_status_pending
    expect(profile.verification_requested_at).to be_present
  end
end
