require "rails_helper"
require "pdf-reader"

RSpec.describe "Buyer orders and receipts", type: :request do
  let(:buyer) { create(:user) }
  let(:other) { create(:user) }
  let(:event) { create(:event, :published, title: "Guam Night Market", starts_at: Time.utc(2030, 1, 2, 8)) }
  let(:order) do
    create(:order, event: event, user: buyer, reference: "HP-RECEIPT", buyer_email: buyer.email,
      subtotal_cents: 5000, service_fee_cents: 250, discount_cents: 500, total_cents: 4750,
      completed_at: Time.utc(2030, 1, 1, 15, 30))
  end

  it "hides account detail and PDFs from another account, including admins" do
    order
    get "/api/v1/me/orders/#{order.id}", headers: auth_headers(other)
    expect(response).to have_http_status(:not_found)
    get "/api/v1/orders/#{order.id}", headers: auth_headers(other)
    expect(response).to have_http_status(:not_found)
    get "/api/v1/orders/#{order.id}/receipt", headers: auth_headers(other)
    expect(response).to have_http_status(:not_found)
    expect(response.headers["Cache-Control"]).to include("no-store")
    get "/api/v1/orders/#{order.id}/receipt", headers: auth_headers(create(:user, :admin))
    expect(response).to have_http_status(:not_found)
  end

  it "renders a no-store PDF with seller, line items, exact totals, payment summary and refund history" do
    type = create(:ticket_type, event: event)
    create(:order_item, order: order, ticket_type: type, name: "General Admission", unit_price_cents: 2500,
      quantity: 2, subtotal_cents: 5000, fee_cents: 250, discount_cents: 500, organizer_proceeds_cents: 4500)
    payment = create(:payment, :succeeded, order: order, amount_cents: 4750,
      provider_payload: { "cardType" => "VISA", "last4" => "4242" })
    create(:refund, order: order, payment: payment, amount_cents: 1000, status: :pending)

    get "/api/v1/orders/#{order.id}/receipt", headers: auth_headers(buyer)
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/pdf")
    expect(response.headers["Cache-Control"]).to include("no-store")
    text = PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join("\n")
    expect(text).to include("HP-RECEIPT", "January 2, 2030 1:30 AM ChST", "Guam Night Market",
      "Sold by", "Tickets by HåfaPass", "General Admission", "$50.00", "$2.50", "$5.00", "Test total (no real charge): $47.50",
      "VISA ending in 4242", "Refund: $10.00", "Pending")
    expect(text).to include("organizer's agent")
    expect(text).to include("TEST — NOT A RECEIPT FOR A REAL CHARGE")
  end

  it "excludes unpaid cancelled checkouts from history and returns 404 for their receipts" do
    unpaid = create(:order, :cancelled, event: event, user: buyer, completed_at: nil)
    get "/api/v1/me/orders", headers: auth_headers(buyer)
    expect(response.parsed_body.fetch("orders").pluck("id")).not_to include(unpaid.id)
    expect(response.headers["Cache-Control"]).to eq("private, no-store")
    get "/api/v1/me/orders/#{unpaid.id}", headers: auth_headers(buyer)
    expect(response.parsed_body).to include("receipt_available" => false, "buyer_status" => "cancelled")
    expect(response.headers["Cache-Control"]).to eq("private, no-store")
    get "/api/v1/orders/#{unpaid.id}", headers: auth_headers(buyer)
    expect(response.headers["Cache-Control"]).to eq("private, no-store")
    get "/api/v1/orders/#{unpaid.id}/receipt", headers: auth_headers(buyer)
    expect(response).to have_http_status(:not_found)
  end

  it "issues correctly labeled receipts for completed complimentary and box-office cash sales" do
    free = create(:order, event: event, user: buyer, subtotal_cents: 0, service_fee_cents: 0, total_cents: 0)
    get "/api/v1/orders/#{free.id}/receipt", headers: auth_headers(buyer)
    expect(response).to have_http_status(:ok)
    expect(PDF::Reader.new(StringIO.new(response.body)).pages.first.text).to include("Complimentary")

    cash = create(:order, event: event, user: buyer)
    create(:payment, :succeeded, order: cash, provider: "door_cash", provider_environment: "live")
    get "/api/v1/orders/#{cash.id}/receipt", headers: auth_headers(buyer)
    expect(response).to have_http_status(:ok)
    expect(PDF::Reader.new(StringIO.new(response.body)).pages.first.text).to include("Cash at door", "Total paid")

    card = create(:order, :cancelled, event: event, user: buyer, completed_at: nil)
    create(:payment, :succeeded, order: card, provider: "clover", provider_environment: "live")
    get "/api/v1/orders/#{card.id}/receipt", headers: auth_headers(buyer)
    expect(response).to have_http_status(:ok)
    expect(PDF::Reader.new(StringIO.new(response.body)).pages.first.text).to include("Total paid")
  end

  it "replaces unsupported emoji in receipt text without losing the purchase" do
    event.update!(title: "Festival \u{1FAE9}")
    get "/api/v1/orders/#{order.id}/receipt", headers: auth_headers(buyer)
    expect(response).to have_http_status(:ok)
    expect(PDF::Reader.new(StringIO.new(response.body)).pages.first.text).to include("Festival ?")
  end

  it "exposes test payment environment and receipt eligibility" do
    create(:payment, :succeeded, order: order)
    get "/api/v1/me/orders/#{order.id}", headers: auth_headers(buyer)
    expect(response.parsed_body).to include("payment_environment" => "test", "receipt_available" => true)
  end

  it "shows an auto-refunded cancelled event once in buyer history and refund detail" do
    event.update!(status: :cancelled)
    payment = create(:payment, :succeeded, order: order, amount_cents: order.total_cents)
    create(:refund, order: order, payment: payment, amount_cents: order.total_cents,
      status: :succeeded, succeeded_at: Time.current)
    order.update!(status: :refunded)

    get "/api/v1/me/orders", headers: auth_headers(buyer)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("orders").count { |entry| entry["id"] == order.id }).to eq(1)
    expect(response.parsed_body.fetch("orders").first).to include("buyer_status" => "refunded",
      "refunded_cents" => order.total_cents, "receipt_available" => true)

    get "/api/v1/me/orders/#{order.id}", headers: auth_headers(buyer)
    expect(response.parsed_body).to include("buyer_status" => "refunded")
    expect(response.parsed_body.fetch("refund_history").length).to eq(1)
    expect(response.parsed_body.dig("cancellation_refund", "status")).to eq("refunded")
  end

  it "returns compact cards with ticket, add-on, and merchandise counts and all purchased items" do
    type = create(:ticket_type, event: event)
    create(:order_item, order: order, ticket_type: type, quantity: 2, name: "Admission")
    expected_names = ["Admission"]
    %i[add_on merchandise].each do |kind|
      catalog_item = create(:catalog_item, event: event, kind: kind)
      expected_names << catalog_item.name
      create(:order_item, order: order, ticket_type: nil, catalog_item: catalog_item,
        item_kind: kind, name: catalog_item.name, quantity: 3)
    end
    get "/api/v1/me/orders", headers: auth_headers(buyer)
    card = response.parsed_body.fetch("orders").find { |entry| entry.fetch("id") == order.id }
    expect(card.fetch("item_counts")).to eq("ticket" => 2, "add_on" => 3, "merchandise" => 3)
    expect(card.fetch("order_items").pluck("name")).to eq(expected_names)
    expect(card).to include("subtotal_cents" => 5000, "service_fee_cents" => 250,
      "discount_cents" => 500, "total_cents" => 4750, "refunded_cents" => 0,
      "receipt_available" => true, "refund_pending" => false)
    expect(card).not_to have_key("tickets")
    expect(card).not_to have_key("confirmation_delivery")
    get "/api/v1/me/orders/#{order.id}", headers: auth_headers(buyer)
    expect(response.parsed_body).to have_key("tickets")
  end

  it "keeps SQL queries bounded for 20 order cards with three tickets each" do
    type = create(:ticket_type, event: event)
    20.times do
      purchase = create(:order, event: event, user: buyer)
      item = create(:order_item, order: purchase, ticket_type: type, quantity: 3)
      3.times { create(:ticket, order: purchase, order_item: item, event: event, ticket_type: type) }
    end
    queries = []
    subscriber = lambda do |*, payload|
      queries << payload[:sql] if payload[:sql]&.match?(/\ASELECT\b/i) && !payload[:cached] && payload[:name] != "SCHEMA"
    end
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      get "/api/v1/me/orders", params: { per_page: 20 }, headers: auth_headers(buyer)
    end
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("orders").size).to eq(20)
    expect(queries.size).to be <= 10
  end

  it "localizes receipt dates and uses the payment capture when completion time is absent" do
    order.update!(locale: "ko", completed_at: nil)
    create(:payment, :succeeded, order: order, succeeded_at: Time.utc(2030, 1, 1, 15, 30))
    get "/api/v1/orders/#{order.id}/receipt", headers: auth_headers(buyer)
    text = PDF::Reader.new(StringIO.new(response.body)).pages.first.text
    expect(text).to include("2030년 1월 2일 01:30 ChST", "2030년 1월 2일 18:00 ChST")
    expect(text).not_to include("January")
  end

  it "uses English date formatting when a saved locale is unsupported" do
    order.update_column(:locale, "fr")
    get "/api/v1/orders/#{order.id}/receipt", headers: auth_headers(buyer)
    text = PDF::Reader.new(StringIO.new(response.body)).pages.first.text
    expect(text).to include("January 2, 2030 1:30 AM ChST")
  end

  it "falls back to creation time, omits zero discount, and shows the refunded total on PDFs" do
    order.update!(completed_at: nil, discount_cents: 0, total_cents: 5250)
    payment = create(:payment, :succeeded, order: order, succeeded_at: nil)
    create(:refund, order: order, payment: payment, amount_cents: 1000, status: :succeeded)
    get "/api/v1/orders/#{order.id}/receipt", headers: auth_headers(buyer)
    text = PDF::Reader.new(StringIO.new(response.body)).pages.first.text
    expect(text).to include("Refunded $10.00")
    expect(text).not_to include("Discount:")
    expect(text).to include(I18n.l(order.created_at.in_time_zone(event.timezone), format: :receipt))
  end

  it "allows a valid guest token to download only its own order receipt" do
    guest = create(:order, event: event, user: nil)
    token = GuestOrderAccess.issue!(guest)
    get "/api/v1/orders/#{guest.id}/receipt", headers: { "X-Guest-Order-Token" => token }
    expect(response).to have_http_status(:ok)
    get "/api/v1/orders/#{order.id}/receipt", headers: { "X-Guest-Order-Token" => token }
    expect(response).to have_http_status(:not_found)
    get "/api/v1/orders/#{guest.id}/receipt"
    expect(response).to have_http_status(:not_found)
  end

  it "falls back to English receipt labels when a saved order locale has no receipt translation" do
    order.update!(locale: "ko")
    get "/api/v1/orders/#{order.id}/receipt", headers: auth_headers(buyer)
    text = PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join("\n")
    expect(text).to include("Order number: HP-RECEIPT", "Total paid: US$47.50")
  end

  it "shows recovered guest orders even when no ticket is retained" do
    guest = create(:order, event: event, user: nil, buyer_email: "guest@example.com")
    headers = auth_headers(buyer)
    allow(ClerkIdentity).to receive(:verified_email_addresses)
      .with(buyer.clerk_id, require_available: true).and_return(["guest@example.com"])
    post "/api/v1/me/orders/recover_guest", headers: headers
    expect(response).to have_http_status(:ok)
    expect(guest.reload.user).to eq(buyer)
    get "/api/v1/me/orders", headers: headers
    expect(response.parsed_body.fetch("orders").pluck("id")).to include(guest.id)
  end

  it "paginates orders newest first with stable ties and only the buyer's records" do
    older = create(:order, user: buyer, created_at: 3.days.ago)
    middle = create(:order, user: buyer, created_at: 2.days.ago)
    newest = create(:order, user: buyer, created_at: 1.day.ago)
    create(:order, user: other, created_at: Time.current)
    get "/api/v1/me/orders", params: { per_page: 2 }, headers: auth_headers(buyer)
    expect(response.parsed_body.fetch("orders").pluck("id")).to eq([newest.id, middle.id])
    expect(response.parsed_body.dig("meta", "next_page")).to eq(2)
    get "/api/v1/me/orders", params: { per_page: 2, page: 2 }, headers: auth_headers(buyer)
    expect(response.parsed_body.fetch("orders").pluck("id")).to eq([older.id])
  end

  it "paginates account tickets without losing later pages" do
    type = create(:ticket_type, event: event)
    tickets = 3.times.map { create(:ticket, order: order, event: event, ticket_type: type, holder_user: buyer) }
    get "/api/v1/me/tickets", params: { per_page: 2 }, headers: auth_headers(buyer)
    expect(response.parsed_body.fetch("tickets").pluck("id")).to eq(tickets.reverse.take(2).map(&:id))
    expect(response.parsed_body.dig("meta", "next_page")).to eq(2)
    get "/api/v1/me/tickets", params: { per_page: 2, page: 2 }, headers: auth_headers(buyer)
    expect(response.parsed_body.fetch("tickets").pluck("id")).to eq([tickets.first.id])
  end
end
