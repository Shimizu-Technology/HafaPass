require "rails_helper"

RSpec.describe "Marketplace discovery", type: :request do
  let(:profile) { create(:organizer_profile, verification_status: :verified) }
  let(:venue) { create(:venue, village: "Tamuning") }
  let(:event) do
    create(:event, :published, organizer_profile: profile, organization: profile.organization, venue: venue,
      starts_at: 2.days.from_now, ends_at: 2.days.from_now + 3.hours, category: :family)
  end
  let!(:ticket_type) { create(:ticket_type, event: event, price_cents: 2000) }

  it "publishes non-empty curated collections and credibility pages" do
    collection = create(:marketplace_collection, title: "Family Weekend")
    collection.marketplace_collection_events.create!(event: event, position: 0)
    create(:marketplace_collection, title: "Empty Shelf")

    get "/api/v1/marketplace_collections"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("collections").pluck("title")).to eq(["Family Weekend"])

    get "/api/v1/marketplace_collections/#{collection.slug}"
    expect(response.parsed_body.fetch("events").first.fetch("slug")).to eq(event.slug)

    empty_collection = MarketplaceCollection.find_by!(title: "Empty Shelf")
    get "/api/v1/marketplace_collections/#{empty_collection.slug}"
    expect(response).to have_http_status(:not_found)

    get "/api/v1/venues/#{venue.slug}"
    expect(response.parsed_body).to include("verified" => true, "village" => "Tamuning")

    get "/api/v1/organizers/#{profile.organization.slug}"
    expect(response.parsed_body).to include("verified" => true)
    expect(response.parsed_body.fetch("events").first.fetch("slug")).to eq(event.slug)
  end

  it "filters paginated inventory by family, village, and transparent price bands" do
    get "/api/v1/events", params: { category: "family", village: "tamuning", price: "under_25", per_page: 1 }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("events").pluck("id")).to eq([event.id])
    expect(response.parsed_body.fetch("meta")).to include("current_page" => 1, "total_count" => 1)
  end

  it "filters on the price buyers currently pay, including active pricing tiers" do
    discounted = create(:event, :published, organizer_profile: profile, organization: profile.organization,
      starts_at: 3.days.from_now, ends_at: 3.days.from_now + 2.hours)
    discounted_ticket = create(:ticket_type, event: discounted, price_cents: 5000)
    create(:pricing_tier, ticket_type: discounted_ticket, price_cents: 1500, tier_type: :time_based,
      starts_at: 1.hour.ago, ends_at: 1.hour.from_now)

    increased = create(:event, :published, organizer_profile: profile, organization: profile.organization,
      starts_at: 4.days.from_now, ends_at: 4.days.from_now + 2.hours)
    increased_ticket = create(:ticket_type, event: increased, price_cents: 1500)
    create(:pricing_tier, ticket_type: increased_ticket, price_cents: 4000, tier_type: :time_based,
      starts_at: 1.hour.ago, ends_at: 1.hour.from_now)

    get "/api/v1/events", params: { price: "under_25", per_page: 20 }

    ids = response.parsed_body.fetch("events").pluck("id")
    expect(ids).to include(event.id, discounted.id)
    expect(ids).not_to include(increased.id)
  end

  it "adds collections, venues, and organizers to the canonical sitemap" do
    collection = create(:marketplace_collection)
    collection.marketplace_collection_events.create!(event: event)

    get "/sitemap.xml"

    expect(response.body).to include("/collections/#{collection.slug}", "/venues/#{venue.slug}",
      "/organizers/#{profile.organization.slug}")
  end

  it "keeps collection and organizer index query counts bounded as shelves grow" do
    first = create(:marketplace_collection)
    first.marketplace_collection_events.create!(event: event)
    baseline = count_select_queries { get "/api/v1/marketplace_collections" }

    4.times do
      collection = create(:marketplace_collection)
      collection.marketplace_collection_events.create!(event: event)
    end
    expanded = count_select_queries { get "/api/v1/marketplace_collections" }
    expect(expanded).to be <= baseline + 2

    4.times do
      another_profile = create(:organizer_profile)
      another_event = create(:event, :published, organizer_profile: another_profile,
        organization: another_profile.organization)
      create(:ticket_type, event: another_event)
    end
    expect(count_select_queries { get "/api/v1/organizers" }).to be <= 8
  end

  def count_select_queries(&block)
    count = 0
    subscriber = lambda do |_name, _start, _finish, _id, payload|
      count += 1 if !payload[:cached] && payload[:name] != "SCHEMA" && payload[:sql].lstrip.start_with?("SELECT")
    end
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record", &block)
    count
  end
end
