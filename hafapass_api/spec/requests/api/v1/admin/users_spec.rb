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
