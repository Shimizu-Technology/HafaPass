require "rails_helper"

# FTC Rule on Unfair or Deceptive Fees (16 CFR Part 464): the all-in price a
# buyer sees first must be what checkout charges. These specs read the public
# listing exactly as the frontend does and prove its advertised totals equal
# the checkout totals for each fee policy and for mixed paid and free carts.
RSpec.describe "Advertised all-in pricing", type: :request do
  let(:event) { create(:event, :published, starts_at: 5.days.from_now) }
  # Awkward prices whose percent fee is not a whole cent exercise rounding.
  let!(:general) { create(:ticket_type, event: event, name: "General", price_cents: 1999, quantity_available: 50, sort_order: 1) }
  let!(:vip) { create(:ticket_type, event: event, name: "VIP", price_cents: 4321, quantity_available: 50, sort_order: 2) }
  let!(:child) { create(:ticket_type, event: event, name: "Child", price_cents: 0, quantity_available: 50, sort_order: 3) }

  before { SiteSetting.instance.update!(service_fee_percent: 5.0, service_fee_flat_cents: 100) }

  def advertised
    get "/api/v1/events/#{event.slug}"
    expect(response).to have_http_status(:ok)
    response.parsed_body.fetch("ticket_types").index_by { |type| type.fetch("id") }
  end

  def checkout(quantities)
    post "/api/v1/orders", params: {
      event_id: event.id, buyer_email: "buyer@example.com", buyer_name: "Buyer", terms_accepted: true,
      terms_version: PolicyRegistry.buyer_terms[:version],
      line_items: quantities.map { |type, quantity| { ticket_type_id: type.id, quantity: quantity } }
    }.to_json, headers: { "Content-Type" => "application/json" }
    expect(response).to have_http_status(:created)
    response.parsed_body
  end

  def expect_advertised_total_to_match_checkout(quantities)
    listing = advertised
    advertised_total = quantities.sum { |type, quantity| listing.fetch(type.id).fetch("all_in_price_cents") * quantity }
    advertised_fee = quantities.sum { |type, quantity| listing.fetch(type.id).fetch("service_fee_cents") * quantity }
    order = checkout(quantities)

    expect(order.fetch("total_cents")).to eq(advertised_total)
    expect(order.fetch("service_fee_cents")).to eq(advertised_fee)
    expect(order.fetch("subtotal_cents") + order.fetch("service_fee_cents")).to eq(order.fetch("total_cents"))
    order
  end

  it "advertises ticket plus fee when the buyer pays and checkout charges exactly that" do
    listing = advertised
    # 5% of $19.99 = 99.95 -> $1.00, plus $1.00 flat.
    expect(listing.fetch(general.id)).to include("current_price_cents" => 1999, "service_fee_cents" => 200,
      "all_in_price_cents" => 2199)
    expect(listing.fetch(child.id)).to include("service_fee_cents" => 0, "all_in_price_cents" => 0)

    expect_advertised_total_to_match_checkout(general => 3, vip => 2)
  end

  it "advertises the ticket price alone when the organizer absorbs the fee" do
    event.update!(fee_policy: :organizer_absorbs, buyer_fee_percent: 0)
    listing = advertised
    expect(listing.fetch(vip.id)).to include("service_fee_cents" => 0, "all_in_price_cents" => 4321)

    order = expect_advertised_total_to_match_checkout(general => 2, vip => 1)
    expect(order.fetch("total_cents")).to eq(2 * 1999 + 4321)
  end

  it "advertises only the buyer share of a split fee" do
    event.update!(fee_policy: :split_fees, buyer_fee_percent: 33)
    listing = advertised
    # VIP fee: 5% of $43.21 = 216.05 -> 216 + 100 = 316; buyer 33% = 104.28 -> 104.
    expect(listing.fetch(vip.id)).to include("service_fee_cents" => 104, "all_in_price_cents" => 4425)

    expect_advertised_total_to_match_checkout(general => 3, vip => 3)
  end

  it "matches advertised totals for mixed paid and free carts under every policy" do
    [[:buyer_pays, 100], [:organizer_absorbs, 0], [:split_fees, 50]].each do |policy, percent|
      event.update!(fee_policy: policy, buyer_fee_percent: percent)
      expect_advertised_total_to_match_checkout(general => 2, vip => 1, child => 4)
    end
  end

  it "advertises the lowest all-in price on marketplace listings with the same rules" do
    get "/api/v1/organizers/#{event.organization.slug}"
    expect(response).to have_http_status(:ok)
    types = response.parsed_body.fetch("events").sole.fetch("ticket_types").index_by { |type| type.fetch("id") }
    expect(types.fetch(general.id)).to include("all_in_price_cents" => 2199, "service_fee_cents" => 200)
  end

  it "names the organizer as the seller on the event and the order" do
    get "/api/v1/events/#{event.slug}"
    seller = response.parsed_body.fetch("seller")
    expect(seller).to include("seller_name" => event.organizer_profile.business_name, "ticketing_service" => "HåfaPass",
      "line" => "Sold by #{event.organizer_profile.business_name} · Tickets by HåfaPass")

    order = checkout(general => 1)
    expect(order.fetch("seller")).to eq(seller)
  end

  it "records the per-ticket rounding on new orders" do
    order = Order.find(checkout(general => 3).fetch("id"))
    expect(order.fee_components.find_by!(kind: "platform").metadata).to include("rounding" => "per_ticket")
    expect(order.order_items.sole).to have_attributes(fee_cents: 600, subtotal_cents: 5997)
  end

  it "charges a seated checkout exactly the all-in prices on the seat map" do
    event.update!(fee_policy: :split_fees, buyer_fee_percent: 40, venue: create(:venue))
    configuration = create(:event_seating_configuration, event: event)
    seats = Array.new(2) { create(:event_seat, event_seating_configuration: configuration, ticket_type: vip) }

    get "/api/v1/events/#{event.slug}/seating"
    expect(response).to have_http_status(:ok)
    map_seats = response.parsed_body.fetch("sections").flat_map { |section| section.fetch("rows") }.flat_map { |row| row.fetch("seats") }
    advertised = map_seats.select { |seat| seats.map(&:id).include?(seat.fetch("id")) }
    expect(advertised.map { |seat| seat.fetch("all_in_price_cents") }.uniq).to eq([vip.price_cents + advertised.first.fetch("service_fee_cents")])

    hold = Seating::HoldAllocator.call(event: event, event_seat_ids: seats.map(&:id), accessibility_attested: false)
    order = Commerce::OrderCreator.call(event: event.reload, line_items: [{ ticket_type_id: vip.id, quantity: 2 }],
      buyer_email: "seat@example.com", buyer_name: "Seat Buyer", seat_hold_token: hold.token, payment_required: false).order
    expect(order.total_cents).to eq(advertised.sum { |seat| seat.fetch("all_in_price_cents") })
    expect(order.service_fee_cents).to eq(advertised.sum { |seat| seat.fetch("service_fee_cents") })
  end

  it "charges a waitlist claim exactly the all-in price on the offer" do
    entry = create(:waitlist_entry, event: event, ticket_type: vip, email: "wait@example.com", quantity: 2)
    offer = create(:waitlist_offer, waitlist_entry: entry, event: event, ticket_type: vip, quantity: 2, unit_price_cents: 3999)
    token = WaitlistCredential.offer(offer)

    get "/api/v1/waitlist_offers/#{token}"
    expect(response).to have_http_status(:ok)
    advertised = response.parsed_body
    # 5% of $39.99 = 199.95 -> $2.00, plus $1.00 flat.
    expect(advertised).to include("unit_price_cents" => 3999, "service_fee_cents" => 300, "all_in_price_cents" => 4299)

    order = Commerce::OrderCreator.call(event: event, line_items: [{ ticket_type_id: vip.id, quantity: 2 }],
      buyer_email: "wait@example.com", buyer_name: "Waitlist Buyer", waitlist_offer_token: token, payment_required: false).order
    expect(order.total_cents).to eq(2 * advertised.fetch("all_in_price_cents"))
  end

  it "applies a promo discount to the ticket price after the advertised all-in total" do
    promo = create(:promo_code, event: event, discount_type: "percentage", discount_value: 10)
    listing = advertised
    advertised_total = 2 * listing.fetch(general.id).fetch("all_in_price_cents")

    order = Commerce::OrderCreator.call(event: event, line_items: [{ ticket_type_id: general.id, quantity: 2 }],
      buyer_email: "promo@example.com", buyer_name: "Promo Buyer", promo_code_id: promo.id, payment_required: false).order

    # The fee stays on the pre-discount price; the discount comes off the tickets.
    expect(order.service_fee_cents).to eq(2 * listing.fetch(general.id).fetch("service_fee_cents"))
    expect(order.discount_cents).to eq((2 * 1999 * 0.10).round)
    expect(order.total_cents).to eq(advertised_total - order.discount_cents)
  end
end
