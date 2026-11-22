# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Events series contract", type: :request do
  let!(:organizer_profile) { create(:organizer_profile) }
  let(:organization) { organizer_profile.organization }
  let!(:series_a) { create(:event_series, organization: organization, name: "FD Tourney 2026", slug: "fd-tourney-2026", status: :active) }
  let!(:series_b) { create(:event_series, organization: organization, name: "Guam Hoops", slug: "guam-hoops", status: :active) }

  let!(:night_1) { create(:event, :published, organizer_profile: organizer_profile, organization: organization, title: "Night 1", starts_at: 2.days.from_now) }
  let!(:championship) { create(:event, :published, organizer_profile: organizer_profile, organization: organization, title: "Championship", starts_at: 4.days.from_now) }
  let!(:standalone) { create(:event, :published, organizer_profile: organizer_profile, organization: organization, title: "Standalone", starts_at: 3.days.from_now) }

  before do
    [night_1, championship, standalone].each { |event| create(:ticket_type, event: event) }
    series_a.event_series_memberships.create!(event: night_1, role: :regular_night, position: 0)
    series_a.event_series_memberships.create!(event: championship, role: :championship_night, position: 1)
    series_b.event_series_memberships.create!(event: championship, role: :other, position: 0)
  end

  it "filters GET /api/v1/events by ?series=<slug> without duplicating multi-series events" do
    get "/api/v1/events", params: { series: "fd-tourney-2026" }

    expect(response).to have_http_status(:ok)
    events = response.parsed_body.fetch("events")
    expect(events.map { |e| e["id"] }).to eq([night_1.id, championship.id])
    expect(events.first.fetch("series")).to eq(
      "id" => series_a.id,
      "slug" => "fd-tourney-2026",
      "name" => "FD Tourney 2026",
      "role" => "regular_night"
    )
    expect(events.last.fetch("series")).to eq(
      "id" => series_a.id,
      "slug" => "fd-tourney-2026",
      "name" => "FD Tourney 2026",
      "role" => "championship_night"
    )
  end

  it "returns series metadata on unfiltered index and show, and nil for standalone events, without N+1 queries" do
    queries = []
    callback = ->(_name, _started, _finished, _id, payload) {
      queries << payload[:sql] if payload[:sql]&.match?(/FROM "(?:event_series|event_series_memberships)"/)
    }

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      get "/api/v1/events"
    end

    expect(response).to have_http_status(:ok)
    by_id = response.parsed_body.fetch("events").index_by { |e| e["id"] }
    expect(by_id.fetch(night_1.id).fetch("series")).to include("slug" => "fd-tourney-2026", "role" => "regular_night")
    expect(by_id.fetch(standalone.id).fetch("series")).to be_nil
    expect(queries.size).to be <= 2

    get "/api/v1/events/#{night_1.slug}"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("series")).to include("slug" => "fd-tourney-2026", "role" => "regular_night")
  end
end
