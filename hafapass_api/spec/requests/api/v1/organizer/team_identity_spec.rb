# frozen_string_literal: true

require "rails_helper"

# Round-2 review: re-inviting someone's email must never reopen, demote or
# remove an existing member, and identity comes from Clerk-verified email.
RSpec.describe "Team invitations never take over existing members", type: :request do
  let(:owner) { create(:user, :organizer, email: "primary@gmail.com") }
  let(:profile) { create(:organizer_profile, user: owner) }
  let(:organization) { profile.organization }
  let(:owner_membership) { organization.organization_memberships.find_by!(user: owner) }
  let(:manager) { create(:user, email: "manager@example.com") }
  let(:event) { create(:event, organizer_profile: profile) }

  before do
    allow(ClerkIdentity).to receive(:verified_email_addresses).and_return([])
    create(:organization_membership, organization: organization, user: manager, role: :manager)
  end

  def headers_for(user)
    auth_headers(user).merge("X-Organization-Id" => organization.id.to_s)
  end

  it "refuses to re-invite the email an owner accepted with (the reported takeover)" do
    owner_membership.update!(invited_email: "work@biz.com")
    headers = headers_for(manager)

    post "/api/v1/organizer/events/#{event.id}/staff_assignments", params: { email: "work@biz.com", role: "scanner" },
      headers: headers
    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to have_key("assignment") # assigned at once, membership untouched
    expect(owner_membership.reload).to have_attributes(role: "owner", status: "active")
    expect(owner_membership).to be_effective

    post "/api/v1/organizer/memberships", params: { email: "work@biz.com", role: "scanner" }, headers: headers_for(owner)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to eq("That person is already on this team")
    expect(owner_membership.reload).to be_owner
  end

  it "recognises members by their Clerk-verified addresses, not by editable contact email" do
    headers = headers_for(owner)
    allow(ClerkIdentity).to receive(:verified_email_addresses).with(owner.clerk_id).and_return(%w[primary@gmail.com other@biz.com])
    post "/api/v1/organizer/memberships", params: { email: "other@biz.com", role: "finance" }, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(owner_membership.reload).to be_owner

    stranger_contact = create(:user, email: "lookalike@example.com") # contact email only, not verified
    create(:organization_membership, organization: organization, user: stranger_contact, role: :marketer)
    allow(ClerkIdentity).to receive(:verified_email_addresses).with(stranger_contact.clerk_id).and_return(["real@example.com"])
    post "/api/v1/organizer/memberships", params: { email: "lookalike@example.com", role: "finance" }, headers: headers
    expect(response).to have_http_status(:created)
    expect(organization.organization_memberships.find_by(user: stranger_contact)).to be_marketer
  end

  it "never reopens an active row whose access end date has passed" do
    ended = create(:organization_membership, organization: organization, user: create(:user), role: :finance,
      invited_email: "ended@example.com", expires_at: 1.day.ago)
    post "/api/v1/organizer/memberships", params: { email: "ended@example.com", role: "scanner" }, headers: headers_for(owner)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(ended.reload).to have_attributes(status: "active", role: "finance")
  end

  it "does not let event-team invites reopen removed or expired invitations" do
    removed = create(:organization_membership, organization: organization, user: nil, invited_email: "gone@example.com",
      status: :revoked, accepted_at: nil, role: :scanner)
    expired = create(:organization_membership, organization: organization, user: nil, invited_email: "late@example.com",
      status: :invited, accepted_at: nil, role: :scanner, invitation_expires_at: 1.day.ago)

    [removed, expired].each do |membership|
      post "/api/v1/organizer/events/#{event.id}/staff_assignments",
        params: { email: membership.invited_email, role: "scanner" }, headers: headers_for(manager)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("Ask the organization owner to re-invite them")
    end
    expect(removed.reload).to be_status_revoked
  end

  it "keeps a pending Owner invitation out of reach of ordinary team changes" do
    admin = create(:user, :admin)
    owner_membership.update!(role: :manager)
    post "/api/v1/admin/organizations/#{organization.id}/memberships", params: { email: "boss@example.com", role: "owner" },
      headers: auth_headers(admin)
    expect(response).to have_http_status(:created)
    invite = OrganizationMembership.find(response.parsed_body["id"])

    post "/api/v1/admin/organizations/#{organization.id}/memberships", params: { email: "boss2@example.com", role: "owner" },
      headers: auth_headers(admin)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to include("already has an owner or an open Owner invitation")

    owner_membership.update!(role: :owner)
    post "/api/v1/organizer/memberships", params: { email: "boss@example.com", role: "scanner" }, headers: headers_for(owner)
    expect(response).to have_http_status(:unprocessable_entity)
    post "/api/v1/organizer/memberships/#{invite.id}/resend", headers: headers_for(owner)
    expect(response).to have_http_status(:unprocessable_entity)
    post "/api/v1/admin/organizations/#{organization.id}/memberships/#{invite.id}/resend", headers: auth_headers(admin)
    expect(response.parsed_body["error"]).to include("already has an owner")
    expect(invite.reload).to be_owner
  end

  it "lets someone removed earlier rejoin on their old row instead of failing" do
    returning = create(:user, email: "back@example.com")
    old = create(:organization_membership, organization: organization, user: returning, role: :finance,
      invited_email: "back@example.com")
    OrganizationTeam.revoke!(membership: old, actor: owner)

    post "/api/v1/organizer/memberships", params: { email: "back@example.com", role: "marketer" }, headers: headers_for(owner)
    token = response.parsed_body.fetch("invitation_token")
    expect(response.parsed_body["invitation_url"]).to include("/organization-invitations/accept?token=")

    post "/api/v1/organization_invitations/accept", params: { token: token }, headers: auth_headers(returning)
    expect(response).to have_http_status(:ok)
    expect(old.reload).to have_attributes(status: "active", role: "marketer")
    expect(organization.organization_memberships.where(user: returning).count).to eq(1)
  end

  it "lets the new owner upload organization images after a transfer" do
    manager_membership = organization.organization_memberships.find_by!(user: manager)
    OrganizationTeam.transfer_ownership!(organization: organization, to_membership: manager_membership, actor: owner)

    expect(OrganizationAuthorization.allowed?(user: manager, organization: organization, permission: :manage_organization))
      .to be(true)
    controller = Api::V1::UploadsController.new
    allow(controller).to receive(:current_user).and_return(manager)
    allow(controller).to receive(:request).and_return(ActionDispatch::TestRequest.create)
    expect(controller.send(:authorized_scope, organization_id: organization.id.to_s)).to eq(event_id: nil, organization_id: organization.id)
  end
end
