# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Organizer team permission regressions", type: :request do
  let(:profile) { create(:organizer_profile) }
  let(:organization) { profile.organization }
  let(:owner) { profile.user }
  let(:event) { create(:event, :published, organizer_profile: profile) }
  let(:headers) { auth_headers(owner).merge("X-Organization-Id" => organization.id.to_s) }

  it "keeps the actual live-pilot pause in force after an organizer resume" do
    chain = create_live_pilot_run
    LivePilotRuns::Manager.pause!(run: chain[:run], actor: create(:user, :admin), reason: "Safety checkpoint")
    pilot = chain[:event]
    post "/api/v1/organizer/events/#{pilot.id}/seating/resume", headers:
      auth_headers(pilot.organizer_profile.user).merge("X-Organization-Id" => pilot.organization_id.to_s)
    expect(response).to have_http_status(:ok)
    expect(pilot.reload.sales_suspension_reason).to eq("[GATE I] Safety checkpoint")
    expect(pilot.sales_blocker).to eq(:sales_paused)
    expect(chain[:run].reload).to be_status_paused
  end

  it "cannot lift a pilot pause by resuming organizer seating sales" do
    event.update!(sales_suspended_at: Time.current, sales_suspension_reason: "[GATE I] Pilot paused")
    post "/api/v1/organizer/events/#{event.id}/seating/resume", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("suspended" => true, "platform_suspended" => true)
    expect(event.reload.sales_suspension_reason).to eq("[GATE I] Pilot paused")
    expect(event.sales_blocker).to eq(:sales_paused)
    expect(Event.discoverable).not_to include(event)
  end

  it "can suspend and resume its own sales without overwriting platform or policy restrictions" do
    event.update!(sales_suspended_at: Time.current, sales_suspension_reason: "Platform investigation")
    post "/api/v1/organizer/events/#{event.id}/seating/suspend", params: { reason: "Fix seat labels" }, headers: headers
    expect(response).to have_http_status(:ok)
    expect(event.reload.organizer_sales_suspension_reason).to eq("Fix seat labels")
    expect(event.sales_suspension_reason).to eq("Platform investigation")
    EventSalesSuspension.lift!(event: event, actor: create(:user, :admin), note: "Investigation complete")
    expect(event.reload).to be_sales_suspended
    expect(event.sales_blocker).to eq(:sales_paused)
    post "/api/v1/organizer/events/#{event.id}/seating/resume", headers: headers
    expect(event.reload).not_to be_sales_suspended
    event.update!(policy_hold_at: Time.current, policy_hold_scope: "sales", policy_hold_reason: "Policy review")
    post "/api/v1/organizer/events/#{event.id}/seating/resume", headers: headers
    expect(response.parsed_body).to include("platform_suspended" => true, "suspended" => true)
    expect(event.reload.sales_blocker).to eq(:event_paused)
  end

  it "rejects foreign-event ticket types on guest creation and update, even in the same organization" do
    own_type = create(:ticket_type, event: event)
    [create(:event, organizer_profile: profile), create(:event)].each do |other|
      foreign_type = create(:ticket_type, event: other)
      post "/api/v1/organizer/events/#{event.id}/guest_list", params: {
        guest_name: "Guest", ticket_type_id: foreign_type.id, quantity: 1
      }, headers: headers
      expect(response).to have_http_status(:not_found)
      expect(event.guest_list_entries.reload).to be_empty
      entry = event.guest_list_entries.create!(guest_name: "Existing guest", ticket_type: own_type, quantity: 1)
      patch "/api/v1/organizer/events/#{event.id}/guest_list/#{entry.id}",
        params: { ticket_type_id: foreign_type.id }, headers: headers
      expect(response).to have_http_status(:not_found)
      expect(entry.reload.ticket_type).to eq(own_type)
      entry.destroy!
      invalid = event.guest_list_entries.build(guest_name: "Direct model", ticket_type: foreign_type, quantity: 1)
      expect(invalid).not_to be_valid
      expect(invalid.errors[:ticket_type]).to include("must belong to this event")
    end
  end

  it "requires organization-level event creation for clone and recurrence despite an event manager assignment" do
    staff = create(:user)
    membership = create(:organization_membership, organization: organization, user: staff, role: :marketer)
    create(:event_staff_assignment, event: event, user: staff, role: :manager)
    staff_headers = auth_headers(staff).merge("X-Organization-Id" => organization.id.to_s)
    get "/api/v1/organizer/events/#{event.id}", headers: staff_headers
    expect(response.parsed_body).to include("can_create_events" => false)
    expect(response.parsed_body.dig("permissions", "manage_events")).to be(true)
    %w[clone generate_recurrences].each do |action|
      expect { post "/api/v1/organizer/events/#{event.id}/#{action}", headers: staff_headers }.not_to change(Event, :count)
      expect(response).to have_http_status(:forbidden)
    end
    membership.update!(role: :manager)
    post "/api/v1/organizer/events/#{event.id}/clone", headers: staff_headers
    expect(response).to have_http_status(:created)
    get "/api/v1/organizer/events/#{response.parsed_body.fetch('id')}", headers: staff_headers
    expect(response).to have_http_status(:ok)
  end

  it "reports ended membership access separately from invitation expiry" do
    membership = create(:organization_membership, organization: organization, role: :scanner, expires_at: 1.minute.ago)
    get "/api/v1/organizer/memberships", headers: headers
    expect(response.parsed_body.find { |row| row['id'] == membership.id }).to include(
      "status" => "active", "invitation_status" => "access_ended")
    expect(membership).not_to be_effective
  end
end
