require "rails_helper"

RSpec.describe "Marketplace discovery", type: :request do
  let(:profile) { create(:organizer_profile, verification_status: :verified) }
  let(:venue) { create(:venue, village: "Tamuning") }
  let(:event) do
    create(:event, :published, organizer_profile: profile, organization: profile.organization, venue: venue,
      starts_at: 2.days.from_now, ends_at: 2.days.from_now + 3.hours, category: :family)
  end
  let!(:ticket_type) { create(:ticket_type, event: event, price_cents: 2000) }

  it "includes the image asset host on organizer listing and detail responses" do
    get "/api/v1/organizers"
    expect(response.parsed_body.fetch("organizers").first).to include("image_asset_host" => S3Service.public_asset_host)
    get "/api/v1/organizers/#{profile.organization.slug}"
    expect(response.parsed_body).to include("image_asset_host" => S3Service.public_asset_host)
  end

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

  it "passes the buyer language through collection, venue, and organizer listings" do
    with_locales_enabled(%w[en ko], machine_translation: true)
    event.update_columns(translations: { "title" => { "ko" => "ko:#{event.title}",
      "_digest" => Translatable.digest(event.title) } })
    collection = create(:marketplace_collection)
    collection.marketplace_collection_events.create!(event: event, position: 0)

    ["/api/v1/marketplace_collections/#{collection.slug}", "/api/v1/venues/#{venue.slug}",
      "/api/v1/organizers/#{profile.organization.slug}"].each do |path|
      get path, headers: { "Accept-Language" => "ko-KR" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("events").first).to include("title" => "ko:#{event.title}",
        "content_locale" => "ko", "machine_translated" => true)
    end
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

  it "filters price bands on the all-in price shown on cards, not the base price" do
    SiteSetting.instance.update!(service_fee_percent: 5.0, service_fee_flat_cents: 100)
    # $23.50 + (5% = $1.18) + $1.00 = $25.68 all-in: over $25 for buyers.
    over = create(:event, :published, organizer_profile: profile, organization: profile.organization,
      starts_at: 3.days.from_now, ends_at: 3.days.from_now + 2.hours)
    create(:ticket_type, event: over, price_cents: 2350)
    # The same ticket with the fee absorbed is $23.50 all-in.
    absorbed = create(:event, :published, organizer_profile: profile, organization: profile.organization,
      starts_at: 3.days.from_now, ends_at: 3.days.from_now + 2.hours, fee_policy: :organizer_absorbs, buyer_fee_percent: 0)
    create(:ticket_type, event: absorbed, price_cents: 2350)
    # $22.85 + $1.14 + $1.00 = $24.99, half of a split fee keeps it lower still.
    under = create(:event, :published, organizer_profile: profile, organization: profile.organization,
      starts_at: 3.days.from_now, ends_at: 3.days.from_now + 2.hours)
    create(:ticket_type, event: under, price_cents: 2285)

    get "/api/v1/events", params: { price: "under_25", per_page: 50 }

    ids = response.parsed_body.fetch("events").pluck("id")
    expect(ids).to include(absorbed.id, under.id)
    expect(ids).not_to include(over.id)
    listed = response.parsed_body.fetch("events").find { |item| item["id"] == under.id }
    expect(listed.fetch("ticket_types").sole.fetch("all_in_price_cents")).to eq(2499)
  end

  it "moves to the next effective price when assigned-seat holds exhaust a quantity tier" do
    tiered_event = create(:event, :published, organizer_profile: profile, organization: profile.organization,
      venue: venue, starts_at: 5.days.from_now, ends_at: 5.days.from_now + 2.hours)
    tiered_ticket = create(:ticket_type, event: tiered_event, price_cents: 5000, quantity_available: 2)
    create(:pricing_tier, ticket_type: tiered_ticket, price_cents: 1500, tier_type: :quantity_based,
      quantity_limit: 1)
    configuration = create(:event_seating_configuration, event: tiered_event)
    assigned_seat = create(:event_seat, event_seating_configuration: configuration, ticket_type: tiered_ticket)
    Seating::HoldAllocator.call(
      event: tiered_event, event_seat_ids: [assigned_seat.id], accessibility_attested: false
    )

    get "/api/v1/events", params: { price: "under_25", per_page: 20 }

    expect(response.parsed_body.fetch("events").pluck("id")).not_to include(tiered_event.id)
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
