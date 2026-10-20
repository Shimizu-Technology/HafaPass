# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin organizations and team management", type: :request do
  let(:admin) { create(:user, :admin, email: "admin@example.com") }
  let(:support) { create(:user, role: :support) }
  let(:organizer) { create(:user, :organizer) }

  it "creates an organization for someone with an emailed owner invitation" do
    post "/api/v1/admin/organizations",
      params: { name: "Ambros Events", owner_email: "Owner@Ambros.test", pre_verified: true },
      headers: auth_headers(admin)

    expect(response).to have_http_status(:created)
    body = response.parsed_body
    expect(body).to include("name" => "Ambros Events")
    expect(body.dig("owner", "email")).to eq("owner@ambros.test")
    expect(body.dig("organizer_profile", "verification_status")).to eq("verified")
    owner_invite = OrganizationMembership.find(body.fetch("memberships").first.fetch("id"))
    expect(owner_invite).to have_attributes(role: "owner", status: "invited")
    expect(MessageDelivery.where(organization_membership: owner_invite, template: "organization_invitation")).to exist
    expect(AuditLog.where(action: "organization.created_by_admin")).to exist

    owner = create(:user, email: "owner@ambros.test")
    post "/api/v1/organization_invitations/accept", params: { token: body.fetch("invitation_token") },
      headers: auth_headers(owner)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("role" => "owner")

    get "/api/v1/organizer_profile", headers: auth_headers(owner)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("verification_status" => "verified", "policy_accepted" => false)
    expect(OrganizerProfile.find(body.dig("organizer_profile", "id")).user).to eq(owner)
  end

  it "keeps organization tools away from support staff and organizers" do
    [support, organizer].each do |user|
      post "/api/v1/admin/organizations", params: { name: "X", owner_email: "x@example.com" }, headers: auth_headers(user)
      expect(response).to have_http_status(:forbidden)
      get "/api/v1/admin/organizations", headers: auth_headers(user)
      expect(response).to have_http_status(:forbidden)
    end
  end

  it "lists and searches organizations with owners and member counts" do
    profile = create(:organizer_profile, business_name: "Nightshade Promotions")
    profile.organization.update!(name: "Nightshade Promotions")
    create(:organizer_profile)

    get "/api/v1/admin/organizations", params: { q: "nightshade" }, headers: auth_headers(admin)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("organizations").pluck("name")).to eq(["Nightshade Promotions"])
    expect(response.parsed_body.fetch("organizations").first).to include("members_count" => 1)
  end

  it "lets an admin manage any organization's team and transfer ownership" do
    profile = create(:organizer_profile)
    organization = profile.organization
    base = "/api/v1/admin/organizations/#{organization.id}/memberships"

    post base, params: { email: "finance@example.com", role: "finance" }, headers: auth_headers(admin)
    expect(response).to have_http_status(:created)
    invite_id = response.parsed_body.fetch("id")

    post base, params: { email: "second-owner@example.com", role: "owner" }, headers: auth_headers(admin)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to include("Transfer ownership")

    patch "#{base}/#{invite_id}", params: { role: "marketer" }, headers: auth_headers(admin)
    expect(response.parsed_body).to include("role" => "marketer")
    post "#{base}/#{invite_id}/resend", headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    delete "#{base}/#{invite_id}", headers: auth_headers(admin)
    expect(response).to have_http_status(:no_content)

    manager = create(:user)
    manager_membership = create(:organization_membership, organization: organization, user: manager, role: :manager)
    post "#{base}/#{manager_membership.id}/transfer_ownership", headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    expect(manager_membership.reload).to be_owner
    expect(organization.organization_memberships.find_by(user: profile.user)).to be_manager

    get "/api/v1/admin/organizations/#{organization.id}", headers: auth_headers(admin)
    expect(response.parsed_body.fetch("memberships").size).to eq(3)
  end

  it "scopes admin membership routes to the organization in the URL" do
    first = create(:organizer_profile).organization
    second = create(:organizer_profile).organization
    membership = second.organization_memberships.first

    patch "/api/v1/admin/organizations/#{first.id}/memberships/#{membership.id}", params: { role: "finance" },
      headers: auth_headers(admin)
    expect(response).to have_http_status(:not_found)
  end

  it "shows the organization an admin opened in their organizer switcher, marked as an admin view" do
    organization = create(:organizer_profile).organization

    get "/api/v1/organizer/organizations", headers: auth_headers(admin).merge("X-Organization-Id" => organization.id.to_s)
    expect(response.parsed_body).to contain_exactly(include("id" => organization.id, "admin_view" => true, "role" => nil))

    get "/api/v1/organizer/organizations", headers: auth_headers(organizer).merge("X-Organization-Id" => organization.id.to_s)
    expect(response.parsed_body).to eq([])
  end

  it "treats the organizer platform role as a derived label" do
    attendee = create(:user)
    patch "/api/v1/admin/users/#{attendee.id}", params: { role: "organizer" }, headers: auth_headers(admin)
    expect(response.parsed_body).to include("role" => "attendee")

    member = create(:organizer_profile).user
    member.update!(role: :support)
    patch "/api/v1/admin/users/#{member.id}", params: { role: "attendee" }, headers: auth_headers(admin)
    expect(response.parsed_body).to include("role" => "organizer")
    expect(response.parsed_body.fetch("organizations").first).to include("role" => "owner")
  end
end
