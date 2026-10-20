# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Platform staff invitations", type: :request do
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

  it "never lowers a role and refuses people who already have it" do
    invite(admin.email, "support")
    expect(response).to have_http_status(:unprocessable_entity)
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
