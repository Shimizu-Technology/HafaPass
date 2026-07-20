# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Organizer organization management", type: :request do
  let(:owner) { create(:user, :organizer) }
  let(:profile) { create(:organizer_profile, user: owner) }
  let(:organization) { profile.organization }
  let(:headers) { auth_headers(owner).merge("X-Organization-Id" => organization.id.to_s) }

  it "invites an email-bound team member and accepts the invitation" do
    post "/api/v1/organizer/memberships", params: { email: "finance@example.com", role: "finance" },
      headers: headers

    expect(response).to have_http_status(:created)
    token = response.parsed_body.fetch("invitation_token")
    membership = organization.organization_memberships.find(response.parsed_body.fetch("id"))
    expect(membership).to be_status_invited
    expect(AuditLog.where(auditable: membership, action: "organization.invitation_created")).to exist

    invitee = create(:user, email: "finance@example.com")
    post "/api/v1/organization_invitations/accept", params: { token: token }, headers: auth_headers(invitee)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("organization_id" => organization.id, "role" => "finance")
    expect(membership.reload).to be_status_active
    expect(membership.user).to eq(invitee)

    delete "/api/v1/organizer/memberships/#{membership.id}", headers: headers
    expect(response).to have_http_status(:no_content)
    post "/api/v1/organizer/memberships", params: { email: "finance@example.com", role: "scanner" },
      headers: headers
    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to include("id" => membership.id, "role" => "scanner", "status" => "invited")
  end

  it "prevents managers from changing membership roles" do
    manager = create(:user)
    create(:organization_membership, organization: organization, user: manager, role: :manager)

    post "/api/v1/organizer/memberships", params: { email: "staff@example.com", role: "scanner" },
      headers: auth_headers(manager).merge("X-Organization-Id" => organization.id.to_s)

    expect(response).to have_http_status(:forbidden)
  end

  it "keeps events and finance data inside the selected organization" do
    own_event = create(:event, organizer_profile: profile)
    other_event = create(:event)

    get "/api/v1/organizer/events/#{other_event.id}", headers: headers
    expect(response).to have_http_status(:not_found)

    get "/api/v1/organizer/events/#{own_event.id}", headers: headers
    expect(response).to have_http_status(:ok)
  end

  it "lists every effective organization so the client can switch context safely" do
    organization
    second_organization = create(:organization)
    create(:organization_membership, organization: second_organization, user: owner, role: :finance)

    get "/api/v1/organizer/organizations", headers: auth_headers(owner)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.pluck("id")).to contain_exactly(organization.id, second_organization.id)
    expect(response.parsed_body.find { |item| item["id"] == second_organization.id }).to include("role" => "finance")
  end

  it "only exposes assigned events to scanner memberships" do
    scanner = create(:user)
    create(:organization_membership, organization: organization, user: scanner, role: :scanner)
    assigned = create(:event, organizer_profile: profile)
    create(:event, organizer_profile: profile)
    create(:event_staff_assignment, organization: organization, event: assigned, user: scanner, role: :scanner)

    get "/api/v1/organizer/events",
      headers: auth_headers(scanner).merge("X-Organization-Id" => organization.id.to_s)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("events").pluck("id")).to eq([assigned.id])
  end

  it "lets finance members view and finalize event statements but not edit event content" do
    finance = create(:user)
    create(:organization_membership, organization: organization, user: finance, role: :finance)
    event = create(:event, :completed, organizer_profile: profile)

    get "/api/v1/organizer/events/#{event.id}/finance",
      headers: auth_headers(finance).merge("X-Organization-Id" => organization.id.to_s)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("preview", "settlements", "payouts", "connected_account")

    post "/api/v1/organizer/events/#{event.id}/finance/finalize",
      headers: auth_headers(finance).merge("X-Organization-Id" => organization.id.to_s)
    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to include("version" => 1, "payable_cents" => 0)

    patch "/api/v1/organizer/events/#{event.id}", params: { title: "Finance should not edit" },
      headers: auth_headers(finance).merge("X-Organization-Id" => organization.id.to_s)
    expect(response).to have_http_status(:forbidden)
  end

  it "lets marketers edit presentation content without creating events or changing operations" do
    marketer = create(:user)
    create(:organization_membership, organization: organization, user: marketer, role: :marketer)
    event = create(:event, organizer_profile: profile)
    original_start = event.starts_at

    patch "/api/v1/organizer/events/#{event.id}", params: {
      description: "Updated campaign copy",
      starts_at: 30.days.from_now.iso8601,
      max_capacity: 1
    }, headers: auth_headers(marketer).merge("X-Organization-Id" => organization.id.to_s)
    expect(response).to have_http_status(:ok)
    expect(event.reload.description).to eq("Updated campaign copy")
    expect(event.starts_at).to be_within(1.second).of(original_start)
    expect(event.max_capacity).to eq(500)

    post "/api/v1/organizer/events", params: { title: "Unauthorized new event" },
      headers: auth_headers(marketer).merge("X-Organization-Id" => organization.id.to_s)
    expect(response).to have_http_status(:forbidden)
  end

  it "starts provider-specific onboarding without claiming Guam Stripe eligibility" do
    post "/api/v1/organizer/connected_accounts", params: { provider: "stripe" }, headers: headers

    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to include("provider" => "stripe", "status" => "onboarding", "payout_ready" => false)
    expect(response.parsed_body.fetch("requirements_due")).to include("guam_eligibility_review")
    expect(response.parsed_body.fetch("next_action")).to include("confirms Guam")
  end
end
