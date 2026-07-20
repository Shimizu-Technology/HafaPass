require "rails_helper"

RSpec.describe "Api::V1::Admin::Users", type: :request do
  let(:admin) { create(:user, :admin) }
  let(:user) { create(:user, role: :attendee) }
  let(:headers) { auth_headers(admin) }

  describe "PATCH /api/v1/admin/users/:id" do
    it "allows an admin to assign a supported role" do
      patch "/api/v1/admin/users/#{user.id}", params: { role: "organizer" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(user.reload).to be_organizer
    end

    it "rejects an unsupported role without changing the user" do
      patch "/api/v1/admin/users/#{user.id}", params: { role: "super_admin" }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include("error" => "Invalid role")
      expect(user.reload).to be_attendee
    end
  end
end


RSpec.describe "Api::V1::Admin::OrganizerProfiles", type: :request do
  let(:admin) { create(:user, :admin) }
  let(:profile) { create(:organizer_profile) }

  it "lets an admin record organizer verification and payout readiness" do
    patch "/api/v1/admin/organizer_profiles/#{profile.id}", params: {
      verification_status: "verified", payout_ready: true
    }, headers: auth_headers(admin)

    expect(response).to have_http_status(:ok)
    expect(profile.reload).to be_verification_status_verified
    expect(profile).to be_payout_ready
    expect(profile.verified_by_user).to eq(admin)
  end
end
