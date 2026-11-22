# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Events performance, caching, and include_sold_out", type: :request do
  let!(:organizer_profile) { create(:organizer_profile) }
  let(:organization) { organizer_profile.organization }
  let!(:series) { create(:event_series, organization: organization, name: "FD Tourney 2026", slug: "fd-tourney-2026", status: :active) }

  def count_sql_queries(&block)
    queries = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      next if payload[:name] == "SCHEMA" || payload[:cached]
      sql = payload[:sql].to_s
      next if sql.match?(/\A\s*(?:BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE SAVEPOINT)/i)

      queries << sql
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
    queries
  end

  describe "N+1 elimination and batched inventory calculations" do
    before do
      # Ensure SiteSetting singleton exists before measuring steady-state index queries.
      SiteSetting.instance

      16.times do |i|
        event = create(
          :event,
          :published,
          organizer_profile: organizer_profile,
          organization: organization,
          title: "Tournament Night #{i + 1}",
          starts_at: (i + 2).days.from_now,
          show_attendees: false
        )
        tt_ga = create(:ticket_type, event: event, name: "General Admission", price_cents: 2500, quantity_available: 100, sort_order: 0)
        create(:ticket_type, :vip, event: event, sort_order: 1)
        create(:pricing_tier, ticket_type: tt_ga, name: "Early Bird", price_cents: 1500, tier_type: :quantity_based, quantity_limit: 20, position: 0)
        create(:catalog_item, event: event, name: "Jersey #{i}", inventory_quantity: 25)
        create(:registration_question, event: event, prompt: "Class year #{i}?")
        create(:event_waiver, event: event, title: "Waiver #{i}")
        series.event_series_memberships.create!(event: event, role: :regular_night, position: i)
      end
    end

    it "keeps SQL query count flat and <= 20 across 16 fully-populated events and skips attendees_preview" do
      queries = count_sql_queries do
        get "/api/v1/events", params: { per_page: 20 }
      end

      expect(response).to have_http_status(:ok)
      events = response.parsed_body.fetch("events")
      expect(events.size).to eq(16)
      expect(events.first.fetch("ticket_types").size).to eq(2)
      expect(events.first.fetch("ticket_types").first.dig("active_tier", "name")).to eq("Early Bird")
      expect(events.first.fetch("catalog_items").size).to eq(1)
      expect(events.first.fetch("registration_questions").size).to eq(1)
      expect(events.first.fetch("waivers").size).to eq(1)
      expect(events.first.fetch("attendees_preview")).to eq([])
      expect(events.first.dig("series", "slug")).to eq("fd-tourney-2026")

      expect(queries.grep(/ROW_NUMBER\(\) OVER/i)).to be_empty
      expect(queries.size).to be <= 20, "Expected <= 20 SQL queries for 16 events, got #{queries.size}:\n#{queries.join("\n")}"
    end

    it "accurately reflects active inventory holds and show_attendees previews using batched queries" do
      event = Event.order(:id).first
      event.update!(show_attendees: true)
      tt = event.ticket_types.order(:sort_order, :id).first
      tier = tt.pricing_tiers.first

      paid_order = create(:order, :completed, event: event)
      create(:ticket, order: paid_order, ticket_type: tt, event: event, attendee_name: "Juan Cruz", status: :issued)
      create(:ticket, order: paid_order, ticket_type: tt, event: event, attendee_name: "Cancelled Guest", status: :cancelled)

      pending_order = create(:order, :pending, event: event)
      order_item = create(:order_item, order: pending_order, ticket_type: tt, pricing_tier: tier, quantity: 3)
      create(:inventory_hold, order: pending_order, order_item: order_item, event: event, ticket_type: tt, pricing_tier: tier, quantity: 3)

      queries = count_sql_queries do
        get "/api/v1/events", params: { per_page: 20 }
      end

      expect(response).to have_http_status(:ok)
      row = response.parsed_body.fetch("events").find { |e| e["id"] == event.id }
      expect(row.fetch("attendee_count")).to eq(1)
      expect(row.fetch("attendees_preview")).to eq(["Juan C."])
      first_tt = row.fetch("ticket_types").first
      expect(first_tt.fetch("quantity_remaining")).to eq(97)
      expect(first_tt.dig("active_tier", "remaining")).to eq(17)
      expect(queries.size).to be <= 21
    end
  end

  describe "bounded 15s server-only MemoryStore cache and safe HTTP headers" do
    let(:memory_cache) { ActiveSupport::Cache::MemoryStore.new(size: 32.megabytes) }
    let!(:event) do
      create(
        :event,
        :published,
        organizer_profile: organizer_profile,
        organization: organization,
        title: "FD Championship Night",
        supported_locales: %w[en ja],
        localized_content: { "ja" => { "title" => "FDチャンピオンシップ" } }
      )
    end
    let!(:ticket_type) { create(:ticket_type, event: event, quantity_available: 100) }

    before do
      SiteSetting.instance
      allow(Rails).to receive(:cache).and_return(memory_cache)
      series.event_series_memberships.create!(event: event, role: :championship_night, position: 0)
    end

    it "serves second unauthenticated GET /api/v1/events from Rails.cache without hitting event tables and preserves headers" do
      first_queries = count_sql_queries { get "/api/v1/events" }
      expect(response).to have_http_status(:ok)
      expect(first_queries.any? { |sql| sql.include?('"events"') }).to be(true)
      expect(response.headers["Cache-Control"]).to eq("private, no-store")
      expect(response.headers["Vary"].split(",").map(&:strip)).to include("Accept-Language", "Authorization")
      expect(response.headers["X-Total-Count"]).to eq("1")

      second_queries = count_sql_queries { get "/api/v1/events" }
      expect(response).to have_http_status(:ok)
      expect(second_queries.grep(/FROM "(?:events|ticket_types|pricing_tiers|tickets|inventory_holds|catalog_items|event_series)"/)).to be_empty
      expect(response.parsed_body.fetch("events").first.fetch("id")).to eq(event.id)
      expect(response.headers["Cache-Control"]).to eq("private, no-store")
      expect(response.headers["Vary"].split(",").map(&:strip)).to include("Accept-Language", "Authorization")
      expect(response.headers["X-Total-Count"]).to eq("1")
      expect(response.headers["X-Page"]).to eq("1")
    end

    it "serves second unauthenticated GET /api/v1/events/:slug from Rails.cache without hitting event tables" do
      first_queries = count_sql_queries { get "/api/v1/events/#{event.slug}" }
      expect(response).to have_http_status(:ok)
      expect(first_queries.any? { |sql| sql.include?('"events"') }).to be(true)
      expect(response.headers["Cache-Control"]).to eq("private, no-store")
      expect(response.headers["Vary"].split(",").map(&:strip)).to include("Accept-Language", "Authorization")

      second_queries = count_sql_queries { get "/api/v1/events/#{event.slug}" }
      expect(response).to have_http_status(:ok)
      expect(second_queries.grep(/FROM "(?:events|ticket_types|pricing_tiers|tickets|inventory_holds|catalog_items)"/)).to be_empty
      expect(response.parsed_body.fetch("slug")).to eq(event.slug)
      expect(response.headers["Cache-Control"]).to eq("private, no-store")
      expect(response.headers["Vary"].split(",").map(&:strip)).to include("Accept-Language", "Authorization")
    end

    it "bypasses cache for authenticated requests and requests with any Authorization header" do
      user = create(:user)
      EventFavorite.create!(user: user, event: event)

      # Populate unauthenticated cache first
      get "/api/v1/events"
      expect(response.parsed_body.fetch("events").first.fetch("favorited")).to be(false)
      get "/api/v1/events/#{event.slug}"
      expect(response.parsed_body.fetch("favorited")).to be(false)

      # Authenticated request must bypass cache and show viewer-specific state
      index_queries = count_sql_queries { get "/api/v1/events", headers: auth_headers(user) }
      expect(response).to have_http_status(:ok)
      expect(index_queries.any? { |sql| sql.include?('"events"') }).to be(true)
      expect(response.parsed_body.fetch("events").first.fetch("favorited")).to be(true)

      show_queries = count_sql_queries { get "/api/v1/events/#{event.slug}", headers: auth_headers(user) }
      expect(response).to have_http_status(:ok)
      expect(show_queries.any? { |sql| sql.include?('"events"') }).to be(true)
      expect(response.parsed_body.fetch("favorited")).to be(true)

      # Even an invalid Authorization header bypasses the unauthenticated cache
      allow(ClerkAuthenticator).to receive(:verify).with("expired-token").and_return(nil)
      bad_auth_queries = count_sql_queries do
        get "/api/v1/events/#{event.slug}", headers: { "Authorization" => "Bearer expired-token" }
      end
      expect(response).to have_http_status(:ok)
      expect(bad_auth_queries.any? { |sql| sql.include?('"events"') }).to be(true)
    end

    it "bypasses cache when preview=true or live_money_proof=true" do
      get "/api/v1/events/#{event.slug}"
      expect(response).to have_http_status(:ok)

      preview_queries = count_sql_queries { get "/api/v1/events/#{event.slug}", params: { preview: "true" } }
      expect(response).to have_http_status(:ok)
      expect(preview_queries.any? { |sql| sql.include?('"events"') }).to be(true)

      proof_queries = count_sql_queries { get "/api/v1/events/#{event.slug}", params: { live_money_proof: "true" } }
      expect(response).to have_http_status(:ok)
      expect(proof_queries.any? { |sql| sql.include?('"events"') }).to be(true)
    end

    it "keeps redirected_from accurate per raw requested slug" do
      old_slug = event.slug
      event.update!(slug: "fd-championship-night-2026")

      get "/api/v1/events/fd-championship-night-2026"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).not_to have_key("redirected_from")

      get "/api/v1/events/#{old_slug}"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("slug" => "fd-championship-night-2026", "redirected_from" => old_slug)

      get "/api/v1/events/#{old_slug.upcase}"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("slug" => "fd-championship-night-2026", "redirected_from" => old_slug.upcase)

      # Re-requesting canonical slug still has no redirected_from
      get "/api/v1/events/fd-championship-night-2026"
      expect(response.parsed_body).not_to have_key("redirected_from")
    end

    it "uses distinct cache keys for Accept-Language and query parameters" do
      with_locales_enabled(%w[ja])

      get "/api/v1/events", headers: { "Accept-Language" => "en" }
      expect(response.parsed_body.fetch("events").first.fetch("title")).to eq("FD Championship Night")

      get "/api/v1/events", headers: { "Accept-Language" => "ja" }
      expect(response.parsed_body.fetch("events").first.fetch("title")).to eq("FDチャンピオンシップ")

      second_event = create(:event, :published, organizer_profile: organizer_profile, organization: organization,
        title: "Night 2", starts_at: 10.days.from_now)
      create(:ticket_type, event: second_event)
      memory_cache.clear

      get "/api/v1/events", params: { per_page: 1, page: 1 }
      page1_id = response.parsed_body.fetch("events").first.fetch("id")

      get "/api/v1/events", params: { per_page: 1, page: 2 }
      page2_id = response.parsed_body.fetch("events").first.fetch("id")
      expect(page2_id).not_to eq(page1_id)

      get "/api/v1/events", params: { organizer: organization.slug, series: "fd-tourney-2026" }
      expect(response.parsed_body.fetch("events").map { |e| e["id"] }).to eq([event.id])
    end

    it "busts index and show caches when SiteSetting.instance is touched" do
      get "/api/v1/events"
      expect(response.parsed_body.fetch("events").first.fetch("title")).to eq("FD Championship Night")
      get "/api/v1/events/#{event.slug}"
      expect(response.parsed_body.fetch("title")).to eq("FD Championship Night")

      event.update_column(:title, "FD Championship Night Updated")
      # Still cached before SiteSetting touch
      get "/api/v1/events/#{event.slug}"
      expect(response.parsed_body.fetch("title")).to eq("FD Championship Night")

      SiteSetting.instance.touch

      get "/api/v1/events"
      expect(response.parsed_body.fetch("events").first.fetch("title")).to eq("FD Championship Night Updated")
      get "/api/v1/events/#{event.slug}"
      expect(response.parsed_body.fetch("title")).to eq("FD Championship Night Updated")
    end

    it "does not cache 404 or 400 error responses" do
      get "/api/v1/events/does-not-exist-yet"
      expect(response).to have_http_status(:not_found)
      expect(memory_cache.instance_variable_get(:@data)).to be_empty

      get "/api/v1/events", params: { series: "fd-tourney-2026" }
      expect(response).to have_http_status(:bad_request)
      expect(memory_cache.instance_variable_get(:@data)).to be_empty
    end
  end

  describe "?include_sold_out=true on GET /api/v1/events" do
    let!(:available_event) do
      create(:event, :published, organizer_profile: organizer_profile, organization: organization,
        title: "Open Night", starts_at: 2.days.from_now)
    end
    let!(:sold_out_event) do
      create(:event, :published, organizer_profile: organizer_profile, organization: organization,
        title: "Championship Pass", starts_at: 3.days.from_now)
    end
    let!(:capacity_full_event) do
      create(:event, :published, organizer_profile: organizer_profile, organization: organization,
        title: "Capacity Full Night", starts_at: 4.days.from_now, max_capacity: 5)
    end
    let!(:draft_event) do
      create(:event, organizer_profile: organizer_profile, organization: organization,
        title: "Draft Night", starts_at: 5.days.from_now)
    end
    let!(:past_sold_out_event) do
      create(:event, :published, organizer_profile: organizer_profile, organization: organization,
        title: "Past Sold Out", starts_at: 2.days.ago)
    end

    before do
      create(:ticket_type, event: available_event, quantity_available: 50, quantity_sold: 10)
      create(:ticket_type, :sold_out, event: sold_out_event)
      create(:ticket_type, event: capacity_full_event, quantity_available: 20, quantity_sold: 5)
      create(:ticket_type, :sold_out, event: draft_event)
      create(:ticket_type, :sold_out, event: past_sold_out_event)

      [available_event, sold_out_event, capacity_full_event, draft_event, past_sold_out_event].each_with_index do |ev, idx|
        series.event_series_memberships.create!(event: ev, role: :regular_night, position: idx)
      end
    end

    it "excludes sold-out events by default and when include_sold_out=true has no organizer/series filter" do
      get "/api/v1/events", params: { organizer: organization.slug }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("events").map { |e| e["id"] }).to eq([available_event.id])

      get "/api/v1/events", params: { include_sold_out: "true" }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("events").map { |e| e["id"] }).to eq([available_event.id])
    end

    it "includes sold-out published upcoming events with sold_out: true when organizer or series filter is present" do
      get "/api/v1/events", params: { organizer: organization.slug, series: series.slug, include_sold_out: "true" }
      expect(response).to have_http_status(:ok)

      events = response.parsed_body.fetch("events")
      by_id = events.index_by { |e| e["id"] }
      expect(by_id.keys).to contain_exactly(available_event.id, sold_out_event.id, capacity_full_event.id)

      expect(by_id.fetch(available_event.id)).to include("purchasable" => true, "sold_out" => false)
      expect(by_id.fetch(sold_out_event.id)).to include("purchasable" => false, "sold_out" => true)
      expect(by_id.fetch(capacity_full_event.id)).to include("purchasable" => false, "sold_out" => true)
    end
  end
end
