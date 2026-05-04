require "rails_helper"

RSpec.describe "Api::V1::Users", type: :request do
  describe "POST /api/v1/users/sync" do
    it "requires authentication" do
      post "/api/v1/users/sync", params: { clerk_id: "attacker", email: "attacker@example.com" }.to_json,
        headers: { "Content-Type" => "application/json" }

      expect(response).to have_http_status(:unauthorized)
      expect(User.find_by(clerk_id: "attacker")).to be_nil
    end

    it "updates the authenticated user instead of trusting caller-supplied clerk_id" do
      user = create(:user, clerk_id: "real_clerk_id", email: "old@example.com")

      post "/api/v1/users/sync",
        params: {
          clerk_id: "spoofed_clerk_id",
          email: "new@example.com",
          first_name: "Jane"
        }.to_json,
        headers: { "Content-Type" => "application/json" }.merge(auth_headers(user))

      expect(response).to have_http_status(:ok)
      expect(user.reload.email).to eq("new@example.com")
      expect(user.first_name).to eq("Jane")
      expect(User.find_by(clerk_id: "spoofed_clerk_id")).to be_nil
    end
  end
end
