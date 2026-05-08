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

    it "can intentionally bootstrap the first production admin when enabled" do
      allow(Rails.env).to receive(:development?).and_return(false)
      allow(Rails.env).to receive(:test?).and_return(false)
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("ADMIN_EMAILS", "").and_return("")
      allow(ENV).to receive(:fetch).with("ENABLE_FIRST_USER_ADMIN_BOOTSTRAP", "false").and_return("true")
      allow(ClerkAuthenticator).to receive(:verify).with("bootstrap_token").and_return({
        "sub" => "bootstrap_clerk_id",
        "email" => "owner@example.com"
      })

      post "/api/v1/users/sync",
        params: { email: "owner@example.com" }.to_json,
        headers: { "Content-Type" => "application/json", "Authorization" => "Bearer bootstrap_token" }

      expect(response).to have_http_status(:ok)
      expect(User.find_by(clerk_id: "bootstrap_clerk_id")).to be_admin
    end

    it "does not bootstrap the first production admin unless explicitly enabled" do
      allow(Rails.env).to receive(:development?).and_return(false)
      allow(Rails.env).to receive(:test?).and_return(false)
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("ADMIN_EMAILS", "").and_return("")
      allow(ENV).to receive(:fetch).with("ENABLE_FIRST_USER_ADMIN_BOOTSTRAP", "false").and_return("false")
      allow(ClerkAuthenticator).to receive(:verify).with("regular_token").and_return({
        "sub" => "regular_clerk_id",
        "email" => "first@example.com"
      })

      post "/api/v1/users/sync",
        params: { email: "first@example.com" }.to_json,
        headers: { "Content-Type" => "application/json", "Authorization" => "Bearer regular_token" }

      expect(response).to have_http_status(:ok)
      expect(User.find_by(clerk_id: "regular_clerk_id")).to be_attendee
    end
  end
end
