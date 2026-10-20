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

    it "cannot turn a changed contact email into organization invitation ownership" do
      attacker = create(:user, role: :attendee, email: "attacker@example.com")
      membership = create(:organization_membership, user: nil, invited_email: "recipient@example.com",
        role: :finance, status: :invited, accepted_at: nil)
      token = OrganizationInvitation.issue!(membership)
      headers = auth_headers(attacker)
      post "/api/v1/users/sync", params: { email: membership.invited_email }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      post "/api/v1/organization_invitations/accept", params: { token: token }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(membership.reload).to be_status_invited
      expect(attacker.reload.email).to eq(membership.invited_email)
    end

    it "does not grant allowlisted admin status without independently verified ownership" do
      allow(Rails.env).to receive(:development?).and_return(false)
      allow(Rails.env).to receive(:test?).and_return(false)
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("ADMIN_EMAILS", "").and_return("admin@example.com")
      allow(ENV).to receive(:fetch).with("ENABLE_FIRST_USER_ADMIN_BOOTSTRAP", "false").and_return("false")
      allow(ClerkIdentity).to receive(:verified_email_addresses).with("clerk_spoof_admin", require_available: true).and_return([])
      allow(ClerkAuthenticator).to receive(:verify).with("spoof_admin").and_return({
        "sub" => "clerk_spoof_admin", "email" => "admin@example.com"
      })
      post "/api/v1/users/sync", params: { email: "admin@example.com" },
        headers: { "Authorization" => "Bearer spoof_admin" }, as: :json
      expect(response).to have_http_status(:ok)
      expect(User.find_by!(clerk_id: "clerk_spoof_admin")).to be_attendee
    end

    it "recognizes a verified allowlisted admin with a standard email-free session token" do
      allow(Rails.env).to receive(:development?).and_return(false)
      allow(Rails.env).to receive(:test?).and_return(false)
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("ADMIN_EMAILS", "").and_return("ADMIN@example.com")
      allow(ClerkIdentity).to receive(:verified_email_addresses).with("clerk_verified_admin", require_available: true).and_return(["admin@example.com"])
      allow(ClerkIdentity).to receive(:profile).with("clerk_verified_admin", timeout: anything).and_return(nil)
      allow(ClerkAuthenticator).to receive(:verify).with("verified_admin").and_return({ "sub" => "clerk_verified_admin" })
      post "/api/v1/users/sync", params: { email: "contact@example.com" },
        headers: { "Authorization" => "Bearer verified_admin" }, as: :json
      expect(response).to have_http_status(:ok)
      expect(User.find_by!(clerk_id: "clerk_verified_admin")).to be_admin
    end

    it "defers first-user creation when the admin identity lookup fails and retries after recovery" do
      allow(Rails.env).to receive(:development?).and_return(false)
      allow(Rails.env).to receive(:test?).and_return(false)
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:fetch).with("ADMIN_EMAILS", "").and_return("admin@example.com")
      allow(ENV).to receive(:[]).with("CLERK_SECRET_KEY").and_return("sk_test_identity_fixture")
      allow(ENV).to receive(:fetch).with("CLERK_SECRET_KEY").and_return("sk_test_identity_fixture")
      allow(ClerkAuthenticator).to receive(:verify).with("retry_admin").and_return({ "sub" => "clerk_retry_admin" })
      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:start).and_yield(http)
      allow(http).to receive(:request).and_raise(Net::ReadTimeout)
      headers = { "Authorization" => "Bearer retry_admin" }

      expect {
        post "/api/v1/users/sync", params: { email: "contact@example.com" }, headers: headers, as: :json
      }.not_to change(User, :count)
      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body).to include("code" => "identity_verification_unavailable", "retryable" => true)
      expect(response.headers["Retry-After"]).to eq("5")
      expect(ClerkIdentity::RequestCache.verified_emails).to be_nil

      allow(http).to receive(:request).and_return(double(code: "200", body: {
        id: "clerk_retry_admin", email_addresses: [
          { email_address: "admin@example.com", verification: { status: "verified" } }
        ]
      }.to_json))
      expect {
        post "/api/v1/users/sync", params: { email: "contact@example.com" }, headers: headers, as: :json
      }.to change(User, :count).by(1)
      expect(response).to have_http_status(:ok)
      expect(User.find_by!(clerk_id: "clerk_retry_admin")).to be_admin
      # The failed attempt makes a short sign-in lookup plus one full-timeout
      # verified-address retry; the recovered attempt needs a single lookup.
      expect(http).to have_received(:request).exactly(3).times
    end

    it "does not re-promote a manually demoted existing allowlisted user" do
      user = create(:user, role: :attendee)
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("ADMIN_EMAILS", "").and_return(user.email)
      allow(ClerkIdentity).to receive(:verified_email_addresses).and_return([user.email])
      post "/api/v1/users/sync", params: { first_name: "Updated" }, headers: auth_headers(user), as: :json
      expect(response).to have_http_status(:ok)
      expect(user.reload).to be_attendee
      expect(ClerkIdentity).not_to have_received(:verified_email_addresses)
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

  describe "account email on first sign-in" do
    let(:headers) { { "Authorization" => "Bearer first_sign_in" } }

    before do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("ADMIN_EMAILS", "").and_return("")
    end

    def sign_in_with(claims)
      allow(ClerkAuthenticator).to receive(:verify).with("first_sign_in").and_return({ "sub" => "clerk_first_sign_in" }.merge(claims))
      get "/api/v1/me/tickets", headers: headers
      expect(response).to have_http_status(:ok)
      User.find_by!(clerk_id: "clerk_first_sign_in")
    end

    it "uses the token's email claim without calling Clerk" do
      allow(ClerkIdentity).to receive(:profile)
      expect(sign_in_with("email" => "claim@example.com").email).to eq("claim@example.com")
      expect(ClerkIdentity).not_to have_received(:profile)
    end

    it "fetches the primary email from Clerk when the session token has none" do
      allow(ClerkIdentity).to receive(:profile).with("clerk_first_sign_in", timeout: ClerkIdentity::SIGN_IN_TIMEOUT)
        .and_return({ email: "fetched@example.com", first_name: "Ana", last_name: "Cruz", verified_emails: ["fetched@example.com"] })
      user = sign_in_with({})
      expect(user).to have_attributes(email: "fetched@example.com", first_name: "Ana", last_name: "Cruz")
      get "/api/v1/me/tickets", headers: headers
      expect(ClerkIdentity).to have_received(:profile).once
    end

    it "still creates the account with a blank email when Clerk is unavailable" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("CLERK_SECRET_KEY").and_return("sk_test_identity_fixture")
      allow(ENV).to receive(:fetch).with("CLERK_SECRET_KEY").and_return("sk_test_identity_fixture")
      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:start).and_yield(http)
      allow(http).to receive(:request).and_raise(Net::ReadTimeout)
      expect(sign_in_with({})).to have_attributes(email: nil, role: "admin")
      expect(http).to have_received(:request).once
      expect(Net::HTTP).to have_received(:start)
        .with("api.clerk.com", 443, hash_including(open_timeout: ClerkIdentity::SIGN_IN_TIMEOUT, read_timeout: ClerkIdentity::SIGN_IN_TIMEOUT))
    end

    it "re-reads the account when a parallel first request inserts it first" do
      winner = create(:user, clerk_id: "clerk_first_sign_in", email: "winner@example.com")
      allow(User).to receive(:find_by).and_call_original
      allow(User).to receive(:find_by).with(clerk_id: "clerk_first_sign_in").and_return(nil, winner)
      allow(ClerkIdentity).to receive(:profile).and_return({ email: "winner@example.com" })
      allow_any_instance_of(User).to receive(:save!).and_raise(ActiveRecord::RecordNotUnique) # rubocop:disable RSpec/AnyInstance

      expect { expect(sign_in_with({})).to eq(winner) }.not_to change(User, :count)
    end

    it "bootstraps an allowlisted admin from the fetched email with a single Clerk lookup" do
      allow(Rails.env).to receive(:development?).and_return(false)
      allow(Rails.env).to receive(:test?).and_return(false)
      allow(ENV).to receive(:fetch).with("ADMIN_EMAILS", "").and_return("boss@example.com")
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("CLERK_SECRET_KEY").and_return("sk_test_identity_fixture")
      allow(ENV).to receive(:fetch).with("CLERK_SECRET_KEY").and_return("sk_test_identity_fixture")
      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:start).and_yield(http)
      allow(http).to receive(:request).and_return(double(code: "200", body: {
        id: "clerk_first_sign_in", primary_email_address_id: "idn_primary", email_addresses: [
          { id: "idn_other", email_address: "other@example.com", verification: { status: "verified" } },
          { id: "idn_primary", email_address: "Boss@example.com", verification: { status: "verified" } }
        ]
      }.to_json))
      expect(sign_in_with({})).to have_attributes(email: "boss@example.com", role: "admin")
      expect(http).to have_received(:request).once
    end

    it "retries the verified-address check at the full timeout after a short sign-in lookup times out" do
      allow(Rails.env).to receive(:development?).and_return(false)
      allow(Rails.env).to receive(:test?).and_return(false)
      allow(ENV).to receive(:fetch).with("ADMIN_EMAILS", "").and_return("boss@example.com")
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("CLERK_SECRET_KEY").and_return("sk_test_identity_fixture")
      allow(ENV).to receive(:fetch).with("CLERK_SECRET_KEY").and_return("sk_test_identity_fixture")
      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:start).and_yield(http)
      calls = 0
      allow(http).to receive(:request) do
        calls += 1
        raise Net::ReadTimeout if calls == 1

        double(code: "200", body: {
          id: "clerk_first_sign_in", primary_email_address_id: "idn_primary", email_addresses: [
            { id: "idn_primary", email_address: "boss@example.com", verification: { status: "verified" } }
          ]
        }.to_json)
      end
      expect(sign_in_with({})).to have_attributes(email: nil, role: "admin")
      expect(Net::HTTP).to have_received(:start)
        .with("api.clerk.com", 443, hash_including(read_timeout: ClerkIdentity::SIGN_IN_TIMEOUT)).ordered
      expect(Net::HTTP).to have_received(:start)
        .with("api.clerk.com", 443, hash_including(read_timeout: ClerkIdentity::DEFAULT_TIMEOUT)).ordered
    end

    it "refills a previously created blank email through the leased profile sync" do
      create(:user, clerk_id: "clerk_first_sign_in", email: nil, role: :attendee)
      allow(ClerkIdentity).to receive(:profile).with("clerk_first_sign_in").and_return({ email: "later@example.com" })
      expect(sign_in_with({}).email).to eq("later@example.com")
      get "/api/v1/me/tickets", headers: headers
      expect(ClerkIdentity).to have_received(:profile).once
    end
  end
end
