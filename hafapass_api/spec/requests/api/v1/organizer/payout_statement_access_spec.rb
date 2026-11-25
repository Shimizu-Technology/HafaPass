# frozen_string_literal: true

require "rails_helper"

# Only roles with view_finance (Owner, Manager, Finance; see ROLE_MATRIX.md)
# see an event's payout statement. Door staff never do, even when assigned to
# the event.
RSpec.describe "Organizer payout statement access", type: :request do
  let(:profile) { create(:organizer_profile, :verified) }
  let(:organization) { profile.organization }
  let(:event) { create(:event, :completed, organization: organization, organizer_profile: profile) }
  let(:other_event) { create(:event, :completed, organization: organization, organizer_profile: profile) }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 1500) }

  def member(role, assigned_role: nil)
    user = create(:user)
    create(:organization_membership, organization: organization, user: user, role: role)
    create(:event_staff_assignment, event: event, user: user, role: assigned_role) if assigned_role
    user
  end

  def headers_for(user)
    auth_headers(user).merge("X-Organization-Id" => organization.id.to_s)
  end

  def paths
    ["/api/v1/organizer/events/#{event.id}/finance/payout_statement",
      "/api/v1/organizer/events/#{event.id}/finance/payout_statement_export"]
  end

  before { record_card_sale!(event, ticket_type: ticket_type, quantity: 2, processing_fee_cents: 0) }

  it "allows owners, managers and finance" do
    [profile.user, member(:manager), member(:finance)].each do |user|
      paths.each do |path|
        get path, headers: headers_for(user)
        expect(response).to have_http_status(:ok), "#{path} for #{user.id}: #{response.body}"
      end
    end
  end

  it "refuses marketers, box office and door scanners, including staff assigned to the event" do
    users = [member(:marketer), member(:box_office, assigned_role: :box_office), member(:scanner, assigned_role: :scanner)]
    users.each do |user|
      paths.each do |path|
        get path, headers: headers_for(user)
        expect(response).to have_http_status(:forbidden), "#{path}: #{response.body}"
        expect(response.body).not_to include("gross_cents", "Ticket sales")
      end
    end
    expect(AuditLog.where(action: "finance.exported")).to be_empty
  end

  it "does not reveal another organization's event or a payout from another event" do
    stranger = create(:organizer_profile, :verified)
    get paths.first, headers: auth_headers(stranger.user).merge("X-Organization-Id" => stranger.organization.id.to_s)
    expect(response).to have_http_status(:not_found)

    other_payout = create(:payout, organization: organization, event: other_event,
      connected_account: create(:connected_account, organization: organization, provider: "manual", with_readiness_approval: false))
    get paths.first, headers: headers_for(profile.user), params: { payout_id: other_payout.id }
    expect(response).to have_http_status(:not_found)
  end

  it "keeps the admin payout schedule to platform administrators" do
    [profile.user, member(:finance)].each do |user|
      get "/api/v1/admin/payout_schedule", headers: auth_headers(user)
      expect(response).to have_http_status(:forbidden)
      %w[reserve release finalize].each do |action|
        post "/api/v1/admin/payout_schedule/#{event.id}/#{action}", headers: auth_headers(user)
        expect(response).to have_http_status(:forbidden)
      end
    end
    expect(event.balance_adjustments).to be_empty
    expect(event.settlements).to be_empty
  end
end
