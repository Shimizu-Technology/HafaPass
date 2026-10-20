# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Organizer team invitations and ownership", type: :request do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  let(:owner) { create(:user, :organizer, email: "owner@example.com") }
  let(:profile) { create(:organizer_profile, user: owner) }
  let(:organization) { profile.organization }
  let(:other_profile) { create(:organizer_profile) }
  let(:other_organization) { other_profile.organization }

  def headers_for(user, org = organization)
    auth_headers(user).merge("X-Organization-Id" => org.id.to_s)
  end

  def member(role, email: nil)
    user = create(:user, **{ email: email }.compact)
    create(:organization_membership, organization: organization, user: user, role: role)
    user
  end

  it "emails invitations, shows their status and supports resend, copy link and revoke" do
    post "/api/v1/organizer/memberships", params: { email: "finance@example.com", role: "finance" },
      headers: headers_for(owner)
    expect(response).to have_http_status(:created)
    body = response.parsed_body
    expect(body).to include("invitation_status" => "pending", "role" => "finance")
    expect(body["invitation_token"]).to be_present
    expect(body.dig("email_delivery", "status")).to eq("queued")
    id = body.fetch("id")

    post "/api/v1/organizer/memberships/#{id}/invitation_link", headers: headers_for(owner)
    expect(response.parsed_body["invitation_token"]).to eq(body["invitation_token"])

    post "/api/v1/organizer/memberships/#{id}/resend", headers: headers_for(owner)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["invitation_token"]).not_to eq(body["invitation_token"])
    expect(MessageDelivery.where(organization_membership_id: id).count).to eq(2)
    expect(AuditLog.where(action: "organization.invitation_resent", auditable_id: id)).to exist

    delete "/api/v1/organizer/memberships/#{id}", headers: headers_for(owner)
    expect(response).to have_http_status(:no_content)
    get "/api/v1/organizer/memberships", headers: headers_for(owner)
    expect(response.parsed_body.find { |item| item["id"] == id }).to include("invitation_status" => "revoked")

    post "/api/v1/organizer/memberships/#{id}/invitation_link", headers: headers_for(owner)
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "shows an expired invitation as expired and lets the owner resend it" do
    post "/api/v1/organizer/memberships", params: { email: "late@example.com", role: "marketer" },
      headers: headers_for(owner)
    membership = OrganizationMembership.find(response.parsed_body.fetch("id"))
    membership.update_column(:invitation_expires_at, 1.minute.ago)

    get "/api/v1/organizer/memberships", headers: headers_for(owner)
    expect(response.parsed_body.find { |item| item["id"] == membership.id }).to include("invitation_status" => "expired")

    post "/api/v1/organizer/memberships/#{membership.id}/resend", headers: headers_for(owner)
    expect(response.parsed_body).to include("invitation_status" => "pending")
  end

  it "keeps invited members' access after the 8th day" do
    post "/api/v1/organizer/memberships", params: { email: "finance@example.com", role: "finance" },
      headers: headers_for(owner)
    token = response.parsed_body.fetch("invitation_token")
    invitee = create(:user, email: "finance@example.com")
    post "/api/v1/organization_invitations/accept", params: { token: token }, headers: auth_headers(invitee)
    expect(response).to have_http_status(:ok)
    expect(invitee.reload).to be_organizer

    travel_to(9.days.from_now) do
      get "/api/v1/organizer/finances", headers: headers_for(invitee)
      expect(response).to have_http_status(:ok)
    end
  end

  it "only lets people who manage members change the team" do
    %i[manager finance marketer box_office scanner].each do |role|
      user = member(role)
      post "/api/v1/organizer/memberships", params: { email: "x-#{role}@example.com", role: "scanner" },
        headers: headers_for(user)
      expect(response).to have_http_status(:forbidden), "#{role} should not invite"
    end
  end

  it "isolates memberships between organizations" do
    foreign = create(:organization_membership, organization: other_organization, user: nil,
      invited_email: "foreign@example.com", status: :invited, accepted_at: nil, role: :finance)

    %w[resend invitation_link transfer_ownership].each do |action|
      post "/api/v1/organizer/memberships/#{foreign.id}/#{action}", headers: headers_for(owner)
      expect(response).to have_http_status(:not_found)
    end
    patch "/api/v1/organizer/memberships/#{foreign.id}", params: { role: "scanner" }, headers: headers_for(owner)
    expect(response).to have_http_status(:not_found)

    post "/api/v1/organizer/memberships", params: { email: "x@example.com", role: "finance" },
      headers: headers_for(owner, other_organization)
    expect(response).to have_http_status(:forbidden)
  end

  it "transfers ownership with an audit trail and refuses non-owners" do
    manager = member(:manager, email: "manager@example.com")
    manager_membership = organization.organization_memberships.find_by(user: manager)

    post "/api/v1/organizer/memberships/#{manager_membership.id}/transfer_ownership", headers: headers_for(manager)
    expect(response).to have_http_status(:forbidden)

    post "/api/v1/organizer/memberships/#{manager_membership.id}/transfer_ownership", headers: headers_for(owner)
    expect(response).to have_http_status(:ok)
    roles = response.parsed_body.to_h { |item| [item["email"], item["role"]] }
    expect(roles).to include("manager@example.com" => "owner", "owner@example.com" => "manager")
    expect(AuditLog.where(action: "organization.ownership_transferred", organization: organization)).to exist

    get "/api/v1/organizer/connected_accounts", headers: headers_for(owner)
    expect(response).to have_http_status(:forbidden)
  end

  it "does not let anyone demote or remove the owner through role changes" do
    owner_membership = organization.organization_memberships.find_by(user: owner)
    patch "/api/v1/organizer/memberships/#{owner_membership.id}", params: { role: "manager" }, headers: headers_for(owner)
    expect(response).to have_http_status(:unprocessable_entity)
    delete "/api/v1/organizer/memberships/#{owner_membership.id}", headers: headers_for(owner)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(owner_membership.reload).to be_owner
  end

  describe "one-step event staff" do
    let(:event) { create(:event, organizer_profile: profile) }

    it "invites a door scanner by email straight onto the event" do
      manager = member(:manager)
      post "/api/v1/organizer/events/#{event.id}/staff_assignments",
        params: { email: "door@example.com", role: "scanner" }, headers: headers_for(manager)
      expect(response).to have_http_status(:created)
      invitation = response.parsed_body.fetch("invitation")
      expect(invitation).to include("email" => "door@example.com", "role" => "scanner", "invitation_status" => "pending")

      get "/api/v1/organizer/events/#{event.id}/staff_assignments", headers: headers_for(manager)
      expect(response.parsed_body.fetch("pending_invitations").pluck("email")).to eq(["door@example.com"])

      door = create(:user, email: "door@example.com")
      post "/api/v1/organization_invitations/accept", params: { token: invitation.fetch("invitation_token") },
        headers: auth_headers(door)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("events").pluck("id")).to eq([event.id])

      get "/api/v1/organizer/events", headers: headers_for(door)
      expect(response.parsed_body.fetch("events").pluck("id")).to eq([event.id])
      expect(OrganizationAuthorization.allowed?(user: door, organization: organization, permission: :scan, event: event))
        .to be(true)
      other_event = create(:event, organizer_profile: profile)
      expect(OrganizationAuthorization.allowed?(user: door, organization: organization, permission: :scan,
        event: other_event)).to be(false)
    end

    it "assigns existing team members immediately" do
      staff = member(:box_office, email: "staff@example.com")
      post "/api/v1/organizer/events/#{event.id}/staff_assignments",
        params: { email: "STAFF@example.com", role: "box_office" }, headers: headers_for(owner)
      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("assignment", "user_id")).to eq(staff.id)
    end

    it "only invites Box office or Door scanner and only for people who manage staff" do
      post "/api/v1/organizer/events/#{event.id}/staff_assignments",
        params: { email: "boss@example.com", role: "manager" }, headers: headers_for(owner)
      expect(response).to have_http_status(:unprocessable_entity)

      %i[marketer finance scanner box_office].each do |role|
        post "/api/v1/organizer/events/#{event.id}/staff_assignments",
          params: { email: "nope@example.com", role: "scanner" }, headers: headers_for(member(role))
        expect(response).to have_http_status(:forbidden), "#{role} should not invite event staff"
      end

      foreign_event = create(:event, organizer_profile: other_profile)
      post "/api/v1/organizer/events/#{foreign_event.id}/staff_assignments",
        params: { email: "x@example.com", role: "scanner" }, headers: headers_for(owner)
      expect(response).to have_http_status(:not_found)
    end

    it "resends and withdraws a pending event invitation" do
      post "/api/v1/organizer/events/#{event.id}/staff_assignments",
        params: { email: "door@example.com", role: "scanner" }, headers: headers_for(owner)
      membership_id = response.parsed_body.dig("invitation", "membership_id")

      post "/api/v1/organizer/events/#{event.id}/staff_invitations/#{membership_id}/resend", headers: headers_for(owner)
      expect(response).to have_http_status(:ok)

      delete "/api/v1/organizer/events/#{event.id}/staff_invitations/#{membership_id}", headers: headers_for(owner)
      expect(response).to have_http_status(:no_content)
      expect(OrganizationMembership.find(membership_id)).to be_status_revoked

      other_event = create(:event, organizer_profile: profile)
      delete "/api/v1/organizer/events/#{other_event.id}/staff_invitations/#{membership_id}", headers: headers_for(owner)
      expect(response).to have_http_status(:not_found)
    end
  end
end
