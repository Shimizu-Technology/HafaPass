require "rails_helper"

RSpec.describe "Buyer order access", type: :request do
  let(:event) { create(:event, :published, starts_at: 5.days.from_now) }
  let(:ticket_type) { create(:ticket_type, event: event, quantity_sold: 1) }
  let(:order) { create(:order, event: event, user: nil) }
  let(:token) { GuestOrderAccess.issue!(order) }
  let(:access_headers) { { "X-Guest-Order-Token" => token } }

  it "restores an authoritative guest order only with its secure token" do
    get "/api/v1/orders/#{order.id}", headers: access_headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("id" => order.id, "reference" => order.reference, "status" => "completed")

    get "/api/v1/orders/#{order.id}"
    expect(response).to have_http_status(:not_found)
  end

  it "accepts a URL token only for read-only bootstrap access" do
    get "/api/v1/orders/#{order.id}", params: { guest_token: token }
    expect(response).to have_http_status(:ok)

    post "/api/v1/orders/#{order.id}/resend", params: { guest_token: token }
    expect(response).to have_http_status(:not_found)
  end

  it "resends fulfillment through the delivery service" do
    delivery = create(:message_delivery, order: order, template: "fulfillment_resend")
    allow(FulfillmentResender).to receive(:call).and_return(delivery)

    post "/api/v1/orders/#{order.id}/resend", headers: access_headers

    expect(response).to have_http_status(:accepted)
    expect(FulfillmentResender).to have_received(:call).with(order: order, requested_by: nil)
  end

  it "does not resend unusable tickets for a fully refunded order" do
    order.update!(status: :refunded, refund_amount_cents: order.total_cents, refunded_at: Time.current)

    post "/api/v1/orders/#{order.id}/resend", headers: access_headers

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to eq("Tickets are not available for this order")
  end

  it "cancels a free ticket, releases inventory, and rotates its scan credential" do
    free_type = create(:ticket_type, :free, event: event, quantity_sold: 1)
    free_order = create(:order, event: event, user: nil, subtotal_cents: 0, service_fee_cents: 0, total_cents: 0)
    item = create(:order_item, order: free_order, ticket_type: free_type, unit_price_cents: 0,
      subtotal_cents: 0, fee_cents: 0, organizer_proceeds_cents: 0)
    ticket = create(:ticket, order: free_order, order_item: item, event: event, ticket_type: free_type)
    credential = ticket.scan_credential
    free_token = GuestOrderAccess.issue!(free_order)

    post "/api/v1/orders/#{free_order.id}/tickets/#{ticket.id}/cancel",
      headers: { "X-Guest-Order-Token" => free_token }

    expect(response).to have_http_status(:ok)
    expect(ticket.reload).to be_cancelled
    expect(free_order.reload).to be_cancelled
    expect(free_type.reload.quantity_sold).to eq(0)
    expect(TicketCredential.find_scan(credential)).to be_nil

    get "/api/v1/orders/#{free_order.id}", headers: { "X-Guest-Order-Token" => free_token }
    expect(response.parsed_body.dig("tickets", 0, "status")).to eq("cancelled")
  end

  it "records that the buyer accepts an event change" do
    change = event.event_changes.create!(change_type: "rescheduled", reason: "Later start",
      before_data: {}, after_data: {}, occurred_at: Time.current)

    post "/api/v1/orders/#{order.id}/event_change_response",
      params: { event_change_id: change.id, decision: "accepted" }, headers: access_headers

    expect(response).to have_http_status(:ok)
    expect(change.event_change_responses.find_by(order: order).decision).to eq("accepted")
  end

  it "rejects a changed decision before performing refund side effects" do
    change = event.event_changes.create!(change_type: "rescheduled", reason: "Later start",
      before_data: {}, after_data: {}, occurred_at: Time.current)
    change.event_change_responses.create!(order: order, decision: "accepted", responded_at: Time.current)
    allow(Commerce::RefundCreator).to receive(:call)

    post "/api/v1/orders/#{order.id}/event_change_response",
      params: { event_change_id: change.id, decision: "refund_requested" },
      headers: access_headers.merge("Idempotency-Key" => SecureRandom.uuid)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(Commerce::RefundCreator).not_to have_received(:call)
    expect(change.event_change_responses.find_by(order: order).decision).to eq("accepted")
  end
end
