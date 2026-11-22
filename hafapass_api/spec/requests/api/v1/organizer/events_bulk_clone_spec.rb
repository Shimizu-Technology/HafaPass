# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Organizer::Events clone & bulk_clone", type: :request do
  let(:user) { create(:user, :organizer) }
  let!(:organizer_profile) { create(:organizer_profile, user: user) }
  let(:organization) { organizer_profile.organization }
  let(:headers) { auth_headers(user).merge("X-Organization-Id" => organization.id.to_s) }
  let!(:venue) { create(:venue, name: "FD Phoenix Center", address: "100 Mangilao Rd", village: "Mangilao") }
  let!(:source_event) do
    create(:event,
      organizer_profile: organizer_profile,
      organization: organization,
      title: "FD Tourney Template",
      venue: venue,
      fee_policy: :split_fees,
      buyer_fee_percent: 50,
      transfers_enabled: true,
      timezone: "Pacific/Guam")
  end
  let!(:ticket_type) { create(:ticket_type, event: source_event, name: "General Admission", price_cents: 1000) }

  describe "POST /api/v1/organizer/events/:id/clone" do
    it "preserves venue_id, fee_policy, buyer_fee_percent, and transfers_enabled when transfers capability is enabled" do
      allow(LaunchCapabilities).to receive(:enabled?).and_call_original
      allow(LaunchCapabilities).to receive(:enabled?).with(:ticket_transfers).and_return(true)

      post "/api/v1/organizer/events/#{source_event.id}/clone", headers: headers

      expect(response).to have_http_status(:created)
      cloned = Event.find(response.parsed_body.fetch("id"))
      expect(cloned.venue_id).to eq(venue.id)
      expect(cloned.fee_policy).to eq("split_fees")
      expect(cloned.buyer_fee_percent).to eq(50)
      expect(cloned.transfers_enabled).to be(true)
    end

    it "forces transfers_enabled to false when ticket_transfers capability is disabled" do
      allow(LaunchCapabilities).to receive(:enabled?).and_call_original
      allow(LaunchCapabilities).to receive(:enabled?).with(:ticket_transfers).and_return(false)

      post "/api/v1/organizer/events/#{source_event.id}/clone", headers: headers

      expect(response).to have_http_status(:created)
      cloned = Event.find(response.parsed_body.fetch("id"))
      expect(cloned.venue_id).to eq(venue.id)
      expect(cloned.fee_policy).to eq("split_fees")
      expect(cloned.buyer_fee_percent).to eq(50)
      expect(cloned.transfers_enabled).to be(false)
    end
  end

  describe "POST /api/v1/organizer/events/:id/bulk_clone" do
    let!(:series) { create(:event_series, organization: organization, name: "FD Tourney 2026") }

    it "clones multiple occurrences atomically and attaches them to a series with ascending positions" do
      existing = create(:event, organizer_profile: organizer_profile, organization: organization, title: "Opening Night")
      series.event_series_memberships.create!(event: existing, role: :regular_night, position: 2)

      post "/api/v1/organizer/events/#{source_event.id}/bulk_clone", params: {
        event_series_id: series.id,
        series_role: "regular_night",
        occurrences: [
          {
            title: "Night 2 - Pool Play",
            starts_at: "2026-12-01T18:00",
            ends_at: "2026-12-01T22:00",
            doors_open_at: "2026-12-01T17:00"
          },
          {
            title: "Night 3 - Pool Play",
            starts_at: "2026-12-02T18:00",
            ends_at: "2026-12-02T22:00"
          }
        ]
      }, headers: headers, as: :json

      expect(response).to have_http_status(:created)
      body = response.parsed_body
      expect(body.fetch("created_count")).to eq(2)
      expect(body.fetch("events").map { |e| e["title"] }).to eq(["Night 2 - Pool Play", "Night 3 - Pool Play"])

      created_events = Event.where(id: body.fetch("events").map { |e| e["id"] }).order(:id)
      expect(created_events.map(&:venue_id)).to eq([venue.id, venue.id])
      expect(created_events.map(&:fee_policy)).to eq(%w[split_fees split_fees])
      expect(created_events.map(&:buyer_fee_percent)).to eq([50, 50])
      expect(created_events.first.ticket_types.count).to eq(1)

      memberships = series.event_series_memberships.reload.order(:position)
      expect(memberships.map(&:position)).to eq([2, 3, 4])
      expect(memberships.last(2).map(&:role)).to eq(%w[regular_night regular_night])
    end

    it "rolls back all occurrences when any occurrence fails validation" do
      expect {
        post "/api/v1/organizer/events/#{source_event.id}/bulk_clone", params: {
          event_series_id: series.id,
          occurrences: [
            { title: "Valid Night", starts_at: "2026-12-01T18:00", ends_at: "2026-12-01T22:00" },
            { title: "Bad Night", starts_at: "2026-12-02T22:00", ends_at: "2026-12-02T18:00" }
          ]
        }, headers: headers, as: :json
      }.not_to change(Event, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("errors").first).to include("Occurrence 2")
      expect(series.event_series_memberships.count).to eq(0)
    end

    it "rejects more than 25 occurrences" do
      occurrences = Array.new(26) do |i|
        { title: "Night #{i + 1}", starts_at: "2026-12-01T18:00", ends_at: "2026-12-01T22:00" }
      end

      post "/api/v1/organizer/events/#{source_event.id}/bulk_clone", params: { occurrences: occurrences },
        headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("25")
    end

    it "refuses events on policy hold" do
      source_event.update_columns(policy_hold_at: Time.current, policy_hold_scope: "sales", policy_hold_reason: "Review")

      post "/api/v1/organizer/events/#{source_event.id}/bulk_clone", params: {
        occurrences: [{ title: "Night 1", starts_at: "2026-12-01T18:00", ends_at: "2026-12-01T22:00" }]
      }, headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("policy hold")
    end

    it "rejects cross-organization event_series_id and unauthorized callers" do
      other_series = create(:event_series, organization: create(:organization))

      post "/api/v1/organizer/events/#{source_event.id}/bulk_clone", params: {
        event_series_id: other_series.id,
        occurrences: [{ title: "Night 1", starts_at: "2026-12-01T18:00", ends_at: "2026-12-01T22:00" }]
      }, headers: headers, as: :json
      expect(response).to have_http_status(:not_found)

      finance_user = create(:user)
      create(:organization_membership, organization: organization, user: finance_user, role: :finance)
      finance_headers = auth_headers(finance_user).merge("X-Organization-Id" => organization.id.to_s)

      post "/api/v1/organizer/events/#{source_event.id}/bulk_clone", params: {
        occurrences: [{ title: "Night 1", starts_at: "2026-12-01T18:00", ends_at: "2026-12-01T22:00" }]
      }, headers: finance_headers, as: :json
      expect(response).to have_http_status(:forbidden)
    end
  end
end
