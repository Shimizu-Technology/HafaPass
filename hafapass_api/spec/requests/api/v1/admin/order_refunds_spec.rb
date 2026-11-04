# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin order refunds", type: :request do
  let(:admin) { create(:user, :admin) }
  let(:event) { create(:event, :published) }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 5000, quantity_available: 10, quantity_sold: 2) }
  let(:order) { create(:order, event: event, subtotal_cents: 10_000, service_fee_cents: 500, total_cents: 10_500) }
  let!(:item) do
    create(:order_item, order: order, ticket_type: ticket_type, quantity: 2, unit_price_cents: 5000,
      subtotal_cents: 10_000, fee_cents: 500, organizer_proceeds_cents: 10_000)
  end
  let!(:tickets) { create_list(:ticket, 2, order: order, order_item: item, event: event, ticket_type: ticket_type) }
  let!(:payment) do
    create(:payment, :succeeded, order: order, amount_cents: 10_500, provider: "stripe",
      provider_environment: "live", provider_payment_id: "pi_admin_refund")
  end
  let(:path) { "/api/v1/admin/orders/#{order.id}/refund" }
  let(:headers) { auth_headers(admin).merge("Idempotency-Key" => "admin-request-1") }

  before do
    allow(EmailService).to receive(:send_refund_notification_async)
    allow(StripeService).to receive(:refund_payment) do |_intent, amount_cents:, **|
      OpenStruct.new(id: "re_admin_#{amount_cents}", status: "succeeded", amount: amount_cents, currency: "usd")
    end
  end

  def refund!(request_headers: headers, **body)
    post path, params: { note: "Duplicate purchase confirmed by phone" }.merge(body), headers: request_headers, as: :json
  end

  it "refunds the remaining balance after payout, cancels unscanned tickets and audits the note" do
    create(:payout, event: event, organization: event.organization, status: :paid)

    refund!

    expect(response).to have_http_status(:created), response.body
    expect(response.parsed_body.dig("refund", "status")).to eq("succeeded")
    expect(response.parsed_body.dig("order", "status")).to eq("refunded")
    expect(StripeService).to have_received(:refund_payment).once
    expect(tickets.map { |ticket| ticket.reload.status }).to all(eq("cancelled"))
    audit = AuditLog.find_by!(action: "order.admin_refund_requested", auditable: order)
    expect(audit).to have_attributes(actor_user_id: admin.id, source: "admin", outcome: "requested")
    expect(audit.metadata).to include("note" => "Duplicate purchase confirmed by phone", "event_paid_out" => true)
  end

  it "still refuses the organizer route after payout, even for an administrator" do
    create(:payout, event: event, organization: event.organization, status: :paid)

    post "/api/v1/organizer/events/#{event.id}/orders/#{order.id}/refund", params: { amount_cents: 1000 }, headers: headers

    expect(response).not_to be_successful
    expect(StripeService).not_to have_received(:refund_payment)
  end

  it "leaves tickets valid for a set amount" do
    refund!(amount_cents: 1500)

    expect(response).to have_http_status(:created), response.body
    expect(response.parsed_body.dig("order", "status")).to eq("partially_refunded")
    expect(tickets.map { |ticket| ticket.reload.status }).to all(eq("issued"))
  end

  it "refunds only a selected ticket that was transferred, and cancels it for its new holder" do
    recipient = create(:user)
    tickets.first.update!(holder_user: recipient)

    refund!(ticket_ids: [tickets.first.id])

    expect(response).to have_http_status(:created), response.body
    expect(response.parsed_body.dig("refund", "amount_cents")).to eq(5250)
    expect(tickets.first.reload).to be_cancelled
    expect(tickets.last.reload).to be_issued
  end

  it "keeps refusing a transferred ticket for a non-administrator buyer path" do
    tickets.first.update!(holder_user: create(:user))

    expect do
      Commerce::RefundCreator.call(order: order, tickets: [tickets.first], reason: "requested_by_customer",
        requested_by: admin, idempotency_key: "not-admin-initiated")
    end.to raise_error(Commerce::RefundCreator::RefundError, /controlled by their current holder/)
  end

  it "replays one Idempotency-Key as one refund and one audit entry" do
    2.times { refund!(amount_cents: 1500) }

    expect(response).to have_http_status(:created), response.body
    expect(order.refunds.count).to eq(1)
    expect(StripeService).to have_received(:refund_payment).once
    expect(AuditLog.where(action: "order.admin_refund_requested", auditable: order).count).to eq(1)
  end

  it "rejects the same key used for a different amount" do
    refund!(amount_cents: 1500)
    refund!(amount_cents: 2000)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]).to include("different refund request")
    expect(order.refunds.count).to eq(1)
  end

  it "reports when a provider failure leaves the outcome unconfirmed" do
    allow(StripeService).to receive(:refund_payment).and_raise(Stripe::APIConnectionError.new("timeout"))

    refund!

    expect(response.parsed_body["reconciliation_required"]).to be(true)
    expect(order.refunds.sole).to be_pending
  end

  it "says no new refund happened when the request is rejected" do
    refund!(amount_cents: 999_999)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to include("error" => "Refund amount exceeds refundable balance", "reconciliation_required" => false)
    expect(StripeService).not_to have_received(:refund_payment)
  end

  [
    [{ note: "" }, "Add a note"],
    [{ amount_cents: "12.50" }, "positive number of cents"],
    [{ amount_cents: -5 }, "positive number of cents"],
    [{ amount_cents: 100, ticket_ids: [1] }, "not both"],
    [{ ticket_ids: [999_999] }, "Ticket not found"]
  ].each do |body, message|
    it "rejects #{body} with no refund" do
      refund!(**body)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to include(message)
      expect(order.refunds).to be_empty
      expect(AuditLog.where(action: "order.admin_refund_requested")).to be_empty
    end
  end

  it "requires an Idempotency-Key" do
    refund!(request_headers: auth_headers(admin))

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]).to include("Idempotency-Key")
  end

  it "does not refund a ticket from another order" do
    other = create(:ticket, order: create(:order, event: event), event: event, ticket_type: ticket_type)

    refund!(ticket_ids: [other.id])

    expect(response.parsed_body["error"]).to include("Ticket not found")
  end

  it "does not let an organizer or support user reach either endpoint" do
    organizer = event.organizer_profile.user

    get "/api/v1/admin/orders/#{order.id}/refund_options", headers: auth_headers(organizer)
    expect(response).to have_http_status(:forbidden)
    post path, params: { note: "x" }, headers: auth_headers(organizer).merge("Idempotency-Key" => "k"), as: :json
    expect(response).to have_http_status(:forbidden)
    expect(order.refunds).to be_empty
  end

  it "shows the refund as a negative balance the organizer owes after payout" do
    create(:payout, event: event, organization: event.organization, status: :paid, amount_cents: 10_000)
    create(:settlement, event: event, organization: event.organization, paid_cents: 10_000)

    expect { refund! }.to change { OrganizationPayoutBalance.available_cents(event.organization) }.by(0)
    expect(response).to have_http_status(:created), response.body
    summary = OrganizationFinanceSummary.call(event.organization)
    expect(summary.dig(:totals, :negative_balance_cents).to_i).to be_positive
  end

  describe "refund options" do
    let(:options_path) { "/api/v1/admin/orders/#{order.id}/refund_options" }

    it "describes the balance, payout state and each ticket" do
      tickets.first.update!(holder_user: create(:user))
      tickets.last.update!(status: :checked_in, checked_in_at: Time.current)
      create(:payout, event: event, organization: event.organization, status: :processing)

      get options_path, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body).to include("refundable_cents" => 10_500, "event_paid_out" => true)
      expect(body).not_to have_key("unavailable_reason")
      expect(body["tickets"].first).to include("refundable_cents" => 5250, "transferred" => true)
      expect(body["tickets"].first).not_to have_key("unavailable_reason")
      expect(body["tickets"].last).to include("unavailable_reason" => "Already scanned")
    end

    it "explains why a door-cash order can't be refunded here" do
      cash_order = create(:order, event: event, payment_method: "door_cash")
      create(:payment, :succeeded, order: cash_order, provider: "door_cash", provider_payment_id: "cash_1")

      get "/api/v1/admin/orders/#{cash_order.id}/refund_options", headers: auth_headers(admin)

      expect(response.parsed_body["unavailable_reason"]).to include("Only Stripe card payments")
    end

    it "explains an order that needs finance review" do
      create(:reconciliation_exception, order: order, payment: payment, code: "refund_terminal_status_conflict")

      get options_path, headers: auth_headers(admin)

      expect(response.parsed_body["unavailable_reason"]).to include("finance review")
    end

    it "returns 404 for an unknown order" do
      get "/api/v1/admin/orders/0/refund_options", headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
    end
  end
end
