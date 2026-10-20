# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Organizer event analytics", type: :request do
  let(:profile) { create(:organizer_profile) }
  let(:organization) { profile.organization }
  let(:headers) { auth_headers(profile.user).merge("X-Organization-Id" => organization.id.to_s) }
  let(:event) { create(:event, :published, organizer_profile: profile, timezone: "Pacific/Guam") }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 2500) }

  def sell!(at:, quantity: 1, source: nil, payment_method: nil, total_cents: 2500 * quantity)
    order = create(:order, event: event, subtotal_cents: total_cents, service_fee_cents: 0, total_cents: total_cents,
      source: source, payment_method: payment_method, completed_at: at, created_at: at)
    item = create(:order_item, order: order, ticket_type: ticket_type, unit_price_cents: total_cents / quantity,
      quantity: quantity, subtotal_cents: total_cents, fee_cents: 0, organizer_proceeds_cents: total_cents)
    quantity.times { create(:ticket, order: order, order_item: item, ticket_type: ticket_type, event: event) }
    order
  end

  def stats
    get "/api/v1/organizer/events/#{event.id}/stats", headers: headers
    expect(response).to have_http_status(:ok)
    response.parsed_body
  end

  it "groups daily sales by the event's own calendar day and fills quiet days" do
    # 15:30 UTC on Oct 1 is 01:30 on Oct 2 in Guam (UTC+10).
    sell!(at: Time.utc(2026, 10, 1, 15, 30), quantity: 2)
    sell!(at: Time.utc(2026, 10, 1, 13, 0))
    sell!(at: Time.utc(2026, 10, 4, 1, 0))
    create(:order, :pending, event: event, created_at: Time.utc(2026, 10, 3, 1, 0))

    body = stats

    expect(body["timezone"]).to eq("Pacific/Guam")
    expect(body["sales_by_day"]).to eq([
      { "date" => "2026-10-01", "orders" => 1, "tickets" => 1, "amount_cents" => 2500 },
      { "date" => "2026-10-02", "orders" => 1, "tickets" => 2, "amount_cents" => 5000 },
      { "date" => "2026-10-03", "orders" => 0, "tickets" => 0, "amount_cents" => 0 },
      { "date" => "2026-10-04", "orders" => 1, "tickets" => 1, "amount_cents" => 2500 }
    ])
  end

  it "returns an empty series before the first sale" do
    expect(stats["sales_by_day"]).to eq([])
    expect(stats["sales_by_channel"].map { |row| row["orders"] }).to eq([0, 0, 0])
  end

  it "splits sales by channel, net of refunds" do
    online = sell!(at: 2.days.ago, quantity: 2)
    refund = create(:refund, order: online, amount_cents: 2500, status: :succeeded, succeeded_at: 1.day.ago)
    create(:refund_item, refund: refund, order_item: online.order_items.first, amount_cents: 2500, organizer_proceeds_cents: 2500)
    online.update!(status: :partially_refunded, refund_amount_cents: 2500)
    sell!(at: 1.day.ago, source: "box_office", payment_method: "door_cash")
    sell!(at: 1.day.ago, source: "guest_list", total_cents: 0)

    expect(stats["sales_by_channel"]).to eq([
      { "channel" => "online", "orders" => 1, "tickets" => 2, "amount_cents" => 2500 },
      { "channel" => "box_office", "orders" => 1, "tickets" => 1, "amount_cents" => 2500 },
      { "channel" => "guest_list", "orders" => 1, "tickets" => 1, "amount_cents" => 0 }
    ])
  end

  def visit!(hash, stage: :event_view, source: nil, medium: nil, order: nil)
    MarketplaceFunnelEvent.create!(event: event, visitor_hash: hash, stage: stage, source: source, medium: medium,
      order: order, occurred_at: 1.day.ago)
  end

  it "withholds a conversion rate while traffic is too thin to mean anything" do
    3.times { |index| visit!("visitor-#{index}") }
    visit!("visitor-0", stage: :purchase)

    traffic = stats["traffic"]

    expect(traffic).to include("visitors" => 3, "purchasers" => 1)
    expect(traffic["conversion"]).to include("estimate" => true, "sufficient_data" => false, "rate" => nil)
  end

  it "estimates conversion from distinct visitors and breaks traffic down by source" do
    20.times { |index| visit!("direct-#{index}") }
    10.times { |index| visit!("ig-#{index}", source: "instagram", medium: "social") }
    visit!("ig-0", source: "instagram", medium: "social")
    order = sell!(at: 1.day.ago)
    AcquisitionAttribution.create!(order: order, source: "instagram", medium: "social", visitor_hash: "ig-0",
      attributed_at: 1.day.ago)
    visit!("ig-0", stage: :purchase, order: order)
    visit!("direct-1", stage: :checkout_started)

    traffic = stats["traffic"]

    expect(traffic).to include("visitors" => 30, "checkout_visitors" => 1, "purchasers" => 1)
    expect(traffic["conversion"]).to include("sufficient_data" => true, "rate" => 0.0333)
    expect(traffic["sources"]).to eq([
      { "source" => "direct", "medium" => "none", "visitors" => 20, "orders" => 0, "amount_cents" => 0 },
      { "source" => "instagram", "medium" => "social", "visitors" => 10, "orders" => 1, "amount_cents" => 2500 }
    ])
  end

  it "keeps sales analytics behind view_finance" do
    marketer = create(:user)
    create(:organization_membership, organization: organization, user: marketer, role: :marketer)

    get "/api/v1/organizer/events/#{event.id}/stats",
      headers: auth_headers(marketer).merge("X-Organization-Id" => organization.id.to_s)

    expect(response).to have_http_status(:forbidden)
  end
end
