require "rails_helper"

RSpec.describe "Api::V1::Me profile backfill", type: :request do
  it "fills an existing email-free session from its own provider and preserves role" do
    user = create(:user, email: nil, first_name: nil, last_name: nil, role: :organizer)
    allow(ClerkAuthenticator).to receive(:verify).with("standard_session").and_return({ "sub" => user.clerk_id })
    allow(ClerkIdentity).to receive(:profile).with(user.clerk_id).and_return({ email: "verified@example.test", first_name: "Real", last_name: "Organizer" })
    headers = { "Authorization" => "Bearer standard_session" }
    get "/api/v1/me", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("email" => "verified@example.test", "first_name" => "Real", "role" => "organizer")
    get "/api/v1/me", headers: headers
    expect(ClerkIdentity).to have_received(:profile).once
    expect(user.reload.email).to eq("verified@example.test")
  end

  it "does not block authenticated account/permission readback on an unavailable provider" do
    user = create(:user, role: :admin)
    allow(ClerkIdentity).to receive(:profile).with(user.clerk_id).and_return(nil)
    get "/api/v1/me", headers: auth_headers(user)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("role" => "admin", "email" => user.email)
  end
end
