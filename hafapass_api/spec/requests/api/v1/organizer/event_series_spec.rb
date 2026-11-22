# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Organizer::EventSeries", type: :request do
  let(:user) { create(:user, :organizer) }
  let!(:organizer_profile) { create(:organizer_profile, user: user) }
  let(:organization) { organizer_profile.organization }
  let(:headers) { auth_headers(user).merge("X-Organization-Id" => organization.id.to_s) }

  describe "CRUD and membership management" do
    it "creates, lists, shows, updates, manages events, and deletes an empty series" do
      post "/api/v1/organizer/event_series", params: {
        name: "FD Alumni Tournament 2026",
        description: "Annual basketball tournament",
        status: "active",
        revenue_share_bps: 3000,
        revenue_share_base: "admissions_net_proceeds",
        revenue_share_includes_door_cash: true,
        revenue_share_label: "School Share",
        primary_share_label: "Alumni Share"
      }, headers: headers, as: :json

      expect(response).to have_http_status(:created)
      series_id = response.parsed_body.fetch("id")
      expect(response.parsed_body).to include(
        "name" => "FD Alumni Tournament 2026",
        "slug" => "fd-alumni-tournament-2026",
        "status" => "active",
        "revenue_share_bps" => 3000,
        "events_count" => 0
      )

      event = create(:event, organizer_profile: organizer_profile, organization: organization, title: "Night 1")

      post "/api/v1/organizer/event_series/#{series_id}/events", params: {
        event_id: event.id,
        role: "regular_night"
      }, headers: headers, as: :json
      expect(response).to have_http_status(:created)
      expect(response.parsed_body.fetch("events_count")).to eq(1)
      expect(response.parsed_body.fetch("events").first).to include(
        "event_id" => event.id,
        "role" => "regular_night",
        "position" => 0
      )

      patch "/api/v1/organizer/event_series/#{series_id}/events/#{event.id}", params: {
        role: "championship_night",
        position: 5
      }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("events").first).to include(
        "role" => "championship_night",
        "position" => 5
      )

      get "/api/v1/organizer/event_series", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("event_series").size).to eq(1)

      get "/api/v1/organizer/event_series/#{series_id}", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("slug")).to eq("fd-alumni-tournament-2026")

      # Refuse destroy while events are attached
      delete "/api/v1/organizer/event_series/#{series_id}", headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("Remove all events")

      # Update status
      patch "/api/v1/organizer/event_series/#{series_id}", params: { status: "archived" }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("status")).to eq("archived")

      # Remove event, then delete series
      delete "/api/v1/organizer/event_series/#{series_id}/events/#{event.id}", headers: headers
      expect(response).to have_http_status(:no_content)

      delete "/api/v1/organizer/event_series/#{series_id}", headers: headers
      expect(response).to have_http_status(:no_content)
      expect(EventSeries.find_by(id: series_id)).to be_nil
    end
  end

  describe "authorization and cross-organization isolation" do
    let!(:series) { create(:event_series, organization: organization) }

    it "allows finance members to read but forbids mutations" do
      finance_user = create(:user)
      create(:organization_membership, organization: organization, user: finance_user, role: :finance)
      finance_headers = auth_headers(finance_user).merge("X-Organization-Id" => organization.id.to_s)

      get "/api/v1/organizer/event_series", headers: finance_headers
      expect(response).to have_http_status(:ok)

      get "/api/v1/organizer/event_series/#{series.id}", headers: finance_headers
      expect(response).to have_http_status(:ok)

      post "/api/v1/organizer/event_series", params: { name: "Blocked" }, headers: finance_headers, as: :json
      expect(response).to have_http_status(:forbidden)

      patch "/api/v1/organizer/event_series/#{series.id}", params: { name: "Blocked" }, headers: finance_headers, as: :json
      expect(response).to have_http_status(:forbidden)

      delete "/api/v1/organizer/event_series/#{series.id}", headers: finance_headers
      expect(response).to have_http_status(:forbidden)
    end

    %i[scanner box_office].each do |role|
      it "forbids assignment-scoped #{role} staff from reading event series" do
        staff_user = create(:user)
        create(:organization_membership, organization: organization, user: staff_user, role: role)
        assigned_event = create(:event, organizer_profile: organizer_profile, organization: organization)
        create(:event_staff_assignment, organization: organization, event: assigned_event, user: staff_user, role: role)
        staff_headers = auth_headers(staff_user).merge("X-Organization-Id" => organization.id.to_s)

        get "/api/v1/organizer/event_series", headers: staff_headers
        expect(response).to have_http_status(:forbidden)

        get "/api/v1/organizer/event_series/#{series.id}", headers: staff_headers
        expect(response).to have_http_status(:forbidden)
      end
    end

    it "returns 422 on duplicate slug and duplicate membership (including RecordNotUnique races)" do
      existing = create(:event_series, organization: organization, name: "Existing", slug: "taken-slug")

      post "/api/v1/organizer/event_series", params: { name: "Another", slug: "taken-slug" }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)

      allow_any_instance_of(EventSeries).to receive(:save).and_raise(ActiveRecord::RecordNotUnique.new("duplicate key"))
      post "/api/v1/organizer/event_series", params: { name: "Race Series", slug: "race-slug" }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("errors")).to include("Slug has already been taken")

      allow_any_instance_of(EventSeries).to receive(:update).and_raise(ActiveRecord::RecordNotUnique.new("duplicate key"))
      patch "/api/v1/organizer/event_series/#{existing.id}", params: { slug: "other-slug" }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("errors")).to include("Slug has already been taken")

      event = create(:event, organizer_profile: organizer_profile, organization: organization)
      series.event_series_memberships.create!(event: event, role: :regular_night, position: 0)

      post "/api/v1/organizer/event_series/#{series.id}/events", params: { event_id: event.id, role: "regular_night" }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)

      other_event = create(:event, organizer_profile: organizer_profile, organization: organization)
      allow_any_instance_of(EventSeriesMembership).to receive(:save).and_raise(ActiveRecord::RecordNotUnique.new("duplicate key"))
      post "/api/v1/organizer/event_series/#{series.id}/events", params: { event_id: other_event.id, role: "regular_night" }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to eq("Event is already in this series")
    end

    it "prevents adding an event from another organization" do
      other_profile = create(:organizer_profile)
      other_event = create(:event, organizer_profile: other_profile, organization: other_profile.organization)

      post "/api/v1/organizer/event_series/#{series.id}/events", params: {
        event_id: other_event.id,
        role: "regular_night"
      }, headers: headers, as: :json

      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 when accessing another organization's series" do
      other_series = create(:event_series, organization: create(:organization))

      get "/api/v1/organizer/event_series/#{other_series.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end
end
