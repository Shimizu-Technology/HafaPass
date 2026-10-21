# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Platform staff invitations", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:admin) { create(:user, :admin, email: "admin@example.com") }

  def invite(email, role)
    post "/api/v1/admin/platform_invitations", params: { email: email, role: role }, headers: auth_headers(admin)
    response.parsed_body
  end

  it "emails an admin invitation and applies the role when the verified email accepts" do
    body = invite("New.Admin@Example.com", "admin")
    expect(response).to have_http_status(:created)
    expect(body).to include("email" => "new.admin@example.com", "role" => "admin", "status" => "pending")
    expect(body["accept_url"]).to include("/platform-invitations/accept?token=")
    invitation = PlatformInvitation.find(body.fetch("id"))
    expect(MessageDelivery.where(platform_invitation: invitation, template: "platform_invitation")).to exist

    token = Rack::Utils.parse_query(URI(body["accept_url"]).query).fetch("token")
    stranger = create(:user, email: "stranger@example.com")
    post "/api/v1/platform_invitations/accept", params: { token: token }, headers: auth_headers(stranger)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(stranger.reload).to be_attendee

    invitee = create(:user, email: "new.admin@example.com")
    post "/api/v1/platform_invitations/accept", params: { token: token }, headers: auth_headers(invitee)
    expect(response).to have_http_status(:ok)
    expect(invitee.reload).to be_admin
    expect(invitation.reload).to be_status_accepted
    expect(AuditLog.where(action: "user.role_updated", auditable: invitee)).to exist
  end

  it "applies a pending support invitation the next time that verified email signs in" do
    invite("helper@example.com", "support")
    helper = create(:user, email: "helper@example.com")

    get "/api/v1/me", headers: auth_headers(helper)

    expect(response.parsed_body).to include("role" => "support")
    expect(PlatformInvitation.last).to be_status_accepted
  end

  it "does not apply an invitation for an unverified contact email" do
    invite("helper@example.com", "support")
    spoofer = create(:user, email: "helper@example.com")
    allow(ClerkIdentity).to receive(:verified_email_addresses).and_return(["someone-else@example.com"])
    headers = auth_headers(spoofer)
    allow(ClerkIdentity).to receive(:verified_email_addresses).with(spoofer.clerk_id).and_return(["other@example.com"])

    get "/api/v1/me", headers: headers
    expect(response.parsed_body).to include("role" => "attendee")
  end

  it "refuses to invite someone who already has that role" do
    invite(admin.email, "support")
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "never lowers a role when an Admin accepts an older Support invitation" do
    body = invite("helper@example.com", "support")
    token = Rack::Utils.parse_query(URI(body["accept_url"]).query).fetch("token")
    helper = create(:user, email: "helper@example.com", role: :admin) # became an admin another way

    post "/api/v1/platform_invitations/accept", params: { token: token }, headers: auth_headers(helper)

    expect(response).to have_http_status(:ok)
    expect(helper.reload).to be_admin
    expect(PlatformInvitation.find(body["id"])).to be_status_accepted
  end

  it "rejects an expired invitation link" do
    body = invite("helper@example.com", "support")
    token = Rack::Utils.parse_query(URI(body["accept_url"]).query).fetch("token")
    helper = create(:user, email: "helper@example.com")

    travel_to(PlatformInvitation::LIFETIME.from_now + 1.hour) do
      post "/api/v1/platform_invitations/accept", params: { token: token }, headers: auth_headers(helper)
    end

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to eq("Invitation is invalid or expired")
    expect(helper.reload).to be_attendee
  end

  it "works when a different admin resends after the original inviter lost admin access" do
    body = invite("helper@example.com", "support")
    admin.update_column(:role, User.roles[:support])
    other_admin = create(:user, :admin)

    post "/api/v1/admin/platform_invitations/#{body['id']}/resend", headers: auth_headers(other_admin)
    expect(response).to have_http_status(:ok)
    expect(PlatformInvitation.find(body["id"]).invited_by_user).to eq(other_admin)
    token = Rack::Utils.parse_query(URI(response.parsed_body["accept_url"]).query).fetch("token")

    helper = create(:user, email: "helper@example.com")
    post "/api/v1/platform_invitations/accept", params: { token: token }, headers: auth_headers(helper)
    expect(response).to have_http_status(:ok)
    expect(helper.reload).to be_support
  end

  it "resends with a new link and revokes pending invitations" do
    body = invite("helper@example.com", "support")
    post "/api/v1/admin/platform_invitations/#{body['id']}/resend", headers: auth_headers(admin)
    expect(response.parsed_body["accept_url"]).not_to eq(body["accept_url"])

    delete "/api/v1/admin/platform_invitations/#{body['id']}", headers: auth_headers(admin)
    expect(response.parsed_body).to include("status" => "revoked")
    expect(response.parsed_body).not_to have_key("accept_url")

    helper = create(:user, email: "helper@example.com")
    get "/api/v1/me", headers: auth_headers(helper)
    expect(response.parsed_body).to include("role" => "attendee")
  end

  it "is admin-only" do
    support = create(:user, role: :support)
    post "/api/v1/admin/platform_invitations", params: { email: "x@example.com", role: "admin" },
      headers: auth_headers(support)
    expect(response).to have_http_status(:forbidden)
    get "/api/v1/admin/platform_invitations", headers: auth_headers(support)
    expect(response).to have_http_status(:forbidden)
  end

  it "stops working when the inviting admin is no longer an admin, and demotion revokes their invitations" do
    body = invite("helper@example.com", "support")
    token = Rack::Utils.parse_query(URI(body["accept_url"]).query).fetch("token")
    admin.update_column(:role, User.roles[:support]) # demoted outside the users screen

    helper = create(:user, email: "helper@example.com")
    post "/api/v1/platform_invitations/accept", params: { token: token }, headers: auth_headers(helper)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to include("Ask a HåfaPass admin")
    get "/api/v1/me", headers: auth_headers(helper)
    expect(response.parsed_body).to include("role" => "attendee")

    admin.update_column(:role, User.roles[:admin])
    other_admin = create(:user, :admin)
    patch "/api/v1/admin/users/#{admin.id}", params: { role: "support" }, headers: auth_headers(other_admin)
    expect(response).to have_http_status(:ok)
    expect(PlatformInvitation.find(body["id"])).to be_status_revoked
  end

  it "remembers an unverified match briefly instead of asking Clerk on every page load" do
    invite("helper@example.com", "support")
    spoofer = create(:user, email: "helper@example.com")
    headers = auth_headers(spoofer)
    allow(ClerkIdentity).to receive(:verified_email_addresses).with(spoofer.clerk_id).and_return(["other@example.com"])
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)

    3.times { get "/api/v1/me", headers: headers }

    expect(ClerkIdentity).to have_received(:verified_email_addresses).with(spoofer.clerk_id).once
    expect(response.parsed_body).to include("role" => "attendee")
  end

  describe "navigation workspace flags on /me" do
    it "offers organizer tools only to people with a workspace and scanning only with scan rights" do
      attendee = create(:user)
      get "/api/v1/me", headers: auth_headers(attendee)
      expect(response.parsed_body["workspace"]).to include("organizer" => false, "scanner" => false)

      profile = create(:organizer_profile)
      marketer = create(:user)
      create(:organization_membership, organization: profile.organization, user: marketer, role: :marketer)
      get "/api/v1/me", headers: auth_headers(marketer)
      expect(response.parsed_body["workspace"]).to include("organizer" => true, "scanner" => false)

      scanner = create(:user)
      create(:organization_membership, organization: profile.organization, user: scanner, role: :scanner)
      get "/api/v1/me", headers: auth_headers(scanner)
      expect(response.parsed_body["workspace"]).to include("scanner" => false)
      create(:event_staff_assignment, organization: profile.organization, user: scanner,
        event: create(:event, organizer_profile: profile))
      get "/api/v1/me", headers: auth_headers(scanner)
      expect(response.parsed_body["workspace"]).to include("organizer" => true, "scanner" => true)

      get "/api/v1/me", headers: auth_headers(profile.user)
      expect(response.parsed_body["workspace"]).to include("organizer" => true, "scanner" => true)
    end
  end
end
