# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Public pricing schedules", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:cutoff) { Time.utc(2027, 5, 1, 13, 59) }
  let(:closes) { cutoff + 5.seconds }
  let(:event) { create(:event, :published, timezone: "Pacific/Guam", starts_at: closes + 1.day, fee_policy: :organizer_absorbs, buyer_fee_percent: 0) }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 5000, sales_end_at: closes) }
  let!(:regular) do
    create(:pricing_tier, :time_based, ticket_type: ticket_type, name: "Regular", starts_at: cutoff, ends_at: closes, price_cents: 5000, position: 0)
  end
  let!(:early) do
    create(:pricing_tier, :time_based, ticket_type: ticket_type, name: "Early Bird", starts_at: nil, ends_at: cutoff, price_cents: 2000, position: 1)
  end

  it "refreshes show and price-filtered index at the exact cutoff even with caching enabled" do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    travel_to(cutoff - 1.second) do
      expect(ticket_type.current_price_cents).to eq(2000)
      get "/api/v1/events/#{event.slug}"
      expect(response.parsed_body.fetch("server_now")).to eq((cutoff - 1.second).iso8601(3))
      schedule = response.parsed_body.fetch("ticket_types").sole.fetch("pricing_schedule")
      expect(schedule).to include("timezone" => "Pacific/Guam", "sales_start_at" => nil, "sales_end_at" => closes.iso8601(6))
      expect(schedule.fetch("active_tier")).to include("id" => early.id, "all_in_price_cents" => 2000, "tier_type" => "time_based")
      expect(schedule.fetch("next_tier")).to include("id" => regular.id, "starts_at" => cutoff.iso8601(6))
      expect(schedule.fetch("time_tiers").pluck("id")).to eq([early.id, regular.id])

      get "/api/v1/events", params: { price: "under_25" }
      expect(response.parsed_body).to include("server_now" => (cutoff - 1.second).iso8601(3))
      expect(response.parsed_body.fetch("events").sole.fetch("ticket_types").sole.fetch("pricing_schedule")).to eq(schedule)
    end

    travel_to(cutoff) do
      expect(early).not_to be_active
      expect(ticket_type.active_pricing_tier).to eq(regular)
      expect(ticket_type.current_price_cents).to eq(5000)
      get "/api/v1/events/#{event.slug}"
      expect(response.parsed_body.fetch("ticket_types").sole.dig("pricing_schedule", "active_tier", "name")).to eq("Regular")

      get "/api/v1/events", params: { price: "under_25" }
      expect(response.parsed_body.fetch("events")).to be_empty
    end

    travel_to(closes) do
      expect(ticket_type).not_to be_on_sale
      get "/api/v1/events/#{event.slug}"
      expect(response.parsed_body.fetch("ticket_types").sole).to include("on_sale" => false)
    end
  end

  it "distinguishes the next scheduled window from an available cap with higher priority" do
    early.update!(position: 0)
    regular.update!(position: 2)
    create(:pricing_tier, ticket_type: ticket_type, position: 1, name: "First 50", price_cents: 3500)

    travel_to(cutoff - 1.second) do
      get "/api/v1/events/#{event.slug}"
      ticket = response.parsed_body.fetch("ticket_types").sole
      expect(ticket.dig("pricing_schedule", "next_tier", "name")).to eq("Regular")
      expect(ticket.fetch("next_tier")).to include("name" => "First 50", "all_in_price_cents" => 3500)
    end
  end

  it "rejects a client-supplied stale price and refuses the exact closing second" do
    params = {
      event_id: event.id, line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
      buyer_name: "Test Buyer", buyer_email: "buyer@example.test",
      terms_accepted: true, terms_version: PolicyRegistry.buyer_terms[:version],
      expected_total_cents: 2000, server_now: (cutoff - 1.second).iso8601, active_tier_id: early.id
    }

    travel_to(cutoff) do
      expect {
        post "/api/v1/orders", params: params.merge(checkout_key: SecureRandom.hex(32)), as: :json
      }.not_to change(Order, :count)
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body).to include(
        "error" => a_kind_of(String), "code" => "price_changed", "server_now" => cutoff.iso8601(3),
        "current_total_cents" => 5000, "checkout_recovery_required" => false,
        "items" => [{
          "ticket_type_id" => ticket_type.id, "name" => ticket_type.name, "active_tier_name" => "Regular",
          "unit_price_cents" => 5000, "all_in_price_cents" => 5000
        }]
      )

      post "/api/v1/orders", params: params.merge(expected_total_cents: 5000, checkout_key: SecureRandom.hex(32)), as: :json
      expect(response).to have_http_status(:created)
      order = Order.find(response.parsed_body.fetch("id"))
      expect(order.order_items.item_ticket.sole).to have_attributes(pricing_tier_id: regular.id, unit_price_cents: 5000)
    end

    travel_to(closes) do
      post "/api/v1/orders", params: params.merge(expected_total_cents: 5000), as: :json
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body).to include("code" => "sales_closed", "server_now" => closes.iso8601(3))
    end
  end
end
