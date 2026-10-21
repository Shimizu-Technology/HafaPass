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
      "Sold by", "Tickets by HåfaPass", "General Admission", "$50.00", "$2.50", "$5.00", "$47.50",
      "VISA ending in 4242", "Refund: $10.00", "Pending")
    expect(text).to include("organizer's agent")
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
