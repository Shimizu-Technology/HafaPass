require "rails_helper"

RSpec.describe "Organizer staff entry permissions", type: :request do
  let(:profile) { create(:organizer_profile) }
  let(:organization) { profile.organization }
  let(:event) { create(:event, organizer_profile: profile) }
  let(:staff) { create(:user) }
  let(:headers) { auth_headers(staff).merge("X-Organization-Id" => organization.id.to_s) }

  before do
    create(:organization_membership, organization: organization, user: staff, role: :scanner)
    create(:event_staff_assignment, organization: organization, event: event, user: staff, role: :scanner)
  end

  it "exposes boolean organization and event permissions without granting editing to scanners" do
    get "/api/v1/organizer/organizations", headers: headers
    permissions = response.parsed_body.find { |item| item["id"] == organization.id }.fetch("permissions")
    expect(permissions).to include("manage_organization" => false, "manage_events" => false)
    expect(permissions.values).to all(satisfy { |value| [true, false].include?(value) })
    get "/api/v1/organizer/events/#{event.id}", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("organization_id" => organization.id)
    expect(response.parsed_body.fetch("permissions")).to include(
      "scan" => true, "edit_event_content" => false, "manage_events" => false, "manage_inventory" => false
    )
  end

  it "rejects scanner setup and event mutations without changing records" do
    profile_before = profile.reload.attributes
    event_before = event.reload.attributes
    event_count = Event.count
    audit_count = AuditLog.count
    [
      [:put, "/api/v1/organizer_profile", { business_name: "Unauthorized scanner change" }],
      [:post, "/api/v1/organizer_profile/accept_policy", {}],
      [:post, "/api/v1/organizer_profile/submit_verification", {}],
      [:post, "/api/v1/organizer/events", { title: "Unauthorized scanner event" }],
      [:put, "/api/v1/organizer/events/#{event.id}", { title: "Unauthorized scanner edit" }],
      [:post, "/api/v1/organizer/events/#{event.id}/publish", {}]
    ].each do |method, path, params|
      public_send(method, path, params: params, headers: headers)
      expect(response).to have_http_status(:forbidden), "#{method} #{path}"
    end
    expect(profile.reload.attributes).to eq(profile_before)
    expect(event.reload.attributes).to eq(event_before)
    expect(Event.count).to eq(event_count)
    expect(AuditLog.count).to eq(audit_count)
  end

  it "honors manager assignment only on its event without granting organization creation" do
    event.event_staff_assignments.find_by!(user: staff).update!(role: :manager)
    other = create(:event, organizer_profile: profile)
    get "/api/v1/organizer/events/#{event.id}", headers: headers
    expect(response.parsed_body.fetch("permissions")).to include("manage_events" => true, "edit_event_content" => true)
    get "/api/v1/organizer/organization", headers: headers
    expect(response.parsed_body.fetch("permissions")).to include("manage_events" => false, "manage_organization" => false)
    get "/api/v1/organizer/events/#{other.id}", headers: headers
    expect(response).to have_http_status(:forbidden)
    event.event_staff_assignments.find_by!(user: staff).update!(expires_at: 1.minute.ago)
    get "/api/v1/organizer/events/#{event.id}", headers: headers
    expect(response).to have_http_status(:forbidden)
  end

  it "preserves platform admin overrides for a selected organization" do
    staff.update!(role: :admin)
    get "/api/v1/organizer/organization", headers: headers
    expect(response.parsed_body.fetch("permissions").values).to all(be(true))
    get "/api/v1/organizer/events/#{event.id}", headers: headers
    expect(response.parsed_body.fetch("permissions").values).to all(be(true))
  end

  it "keeps presentation editors out of operations and inventory" do
    organization.organization_memberships.find_by!(user: staff).update!(role: :marketer)
    event.event_staff_assignments.find_by!(user: staff).destroy!
    get "/api/v1/organizer/events/#{event.id}", headers: headers
    expect(response.parsed_body.fetch("permissions")).to include("edit_event_content" => true,
      "manage_events" => false, "manage_inventory" => false, "scan" => false)
  end
  it "rejects explicit invalid or profile-missing organization context without falling back to an owned profile" do
    own_profile = create(:organizer_profile, user: staff)
    missing_profile_organization = create(:organization)
    create(:organization_membership, organization: missing_profile_organization, user: staff, role: :owner)
    own_before = own_profile.reload.attributes
    organization_count = Organization.count
    profile_count = OrganizerProfile.count
    [
      [Organization.maximum(:id) + 100, :forbidden],
      [missing_profile_organization.id, :not_found]
    ].each do |id, status|
      scoped_headers = auth_headers(staff).merge("X-Organization-Id" => id.to_s)
      [
        [:get, "/api/v1/organizer_profile", {}],
        [:put, "/api/v1/organizer_profile", { business_name: "Wrong context" }],
        [:post, "/api/v1/organizer_profile", { business_name: "Phantom organization" }],
        [:post, "/api/v1/organizer_profile/accept_policy", {}],
        [:post, "/api/v1/organizer_profile/submit_verification", {}]
      ].each do |method, path, params|
        public_send(method, path, params: params, headers: scoped_headers)
        expect(response).to have_http_status(status), "#{id}: #{method} #{path}"
      end
    end
    expect(own_profile.reload.attributes).to eq(own_before)
    expect(Organization.count).to eq(organization_count)
    expect(OrganizerProfile.count).to eq(profile_count)
  end

  it "preserves no-header first-time organizer creation" do
    newcomer = create(:user)
    post "/api/v1/organizer_profile", params: { business_name: "New event team" }, headers: auth_headers(newcomer)
    expect(response).to have_http_status(:created)
    expect(newcomer.reload.organizer_profile.business_name).to eq("New event team")
    expect(newcomer.organization_memberships.sole.role).to eq("owner")
  end
end
