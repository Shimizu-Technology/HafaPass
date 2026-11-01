# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin early fraud warning refunds", type: :request do
  let(:admin) { create(:user, :admin) }
  let(:event) { create(:event, :published) }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 5000, quantity_available: 10, quantity_sold: 2) }
  let(:order) { create(:order, event: event, subtotal_cents: 10_000, service_fee_cents: 500, total_cents: 10_500) }
  let!(:item) do
    create(:order_item, order: order, ticket_type: ticket_type, quantity: 2, unit_price_cents: 5000,
      subtotal_cents: 10_000, fee_cents: 500, organizer_proceeds_cents: 10_000)
  end
  let!(:tickets) { create_list(:ticket, 2, order: order, order_item: item, event: event, ticket_type: ticket_type) }
  let!(:payment) { create(:payment, :succeeded, order: order, provider_environment: "live", provider_payment_id: "pi_fraud") }
  let!(:warning) do
    create(:reconciliation_exception, order: order, payment: payment, code: "early_fraud_warning",
      details: { "warning_id" => "issfr_1", "fraud_type" => "made_with_stolen_card", "actionable" => true })
  end
  let(:path) { "/api/v1/admin/orders/#{order.id}/fraud_refund" }

  before do
    allow(EmailService).to receive(:send_refund_notification_async)
    allow(StripeService).to receive(:refund_payment).and_return(OpenStruct.new(id: "re_fraud", status: "succeeded",
      amount: 10_500, currency: "usd"))
  end

  it "refunds the whole order as fraudulent, cancels its tickets and audits the note and resolution" do
    post path, params: { reconciliation_exception_id: warning.id, note: "Issuer says stolen card" }, headers: auth_headers(admin), as: :json

    expect(response).to have_http_status(:created), response.body
    expect(StripeService).to have_received(:refund_payment).with("pi_fraud", amount_cents: 10_500, reason: "fraudulent",
      idempotency_key: "early-fraud-warning:#{warning.id}", payment: payment)
    expect(order.reload).to be_refunded
    expect(tickets.map { |ticket| ticket.reload.status }).to eq(%w[cancelled cancelled])
    expect(warning.reload).to be_resolved
    requested = AuditLog.find_by!(action: "order.fraud_refund_requested", auditable: order)
    expect(requested).to have_attributes(actor_user_id: admin.id, source: "admin", outcome: "requested")
    expect(requested.metadata).to include("note" => "Issuer says stolen card", "reconciliation_exception_id" => warning.id)
    expect(AuditLog.find_by!(action: "reconciliation_exception.resolved", auditable: warning).metadata)
      .to include("refund_id" => order.refunds.sole.id)
    expect(response.parsed_body.dig("order", "reconciliation_exceptions").find { |entry| entry["id"] == warning.id })
      .to include("code" => "early_fraud_warning", "status" => "resolved", "fraud_type" => "made_with_stolen_card")

    post path, params: { reconciliation_exception_id: warning.id, note: "Again" }, headers: auth_headers(admin), as: :json
    expect(response).to have_http_status(:created)
    expect(order.refunds.count).to eq(1)
    expect(StripeService).to have_received(:refund_payment).once
  end

  it "requires an administrator, a note and an early fraud warning on this order" do
    post path, params: { reconciliation_exception_id: warning.id, note: "x" }, headers: auth_headers(create(:user)), as: :json
    expect(response).to have_http_status(:forbidden)

    post path, params: { reconciliation_exception_id: warning.id, note: " " }, headers: auth_headers(admin), as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]).to include("note")

    other = create(:reconciliation_exception, order: order, payment: payment, code: "payment_amount_mismatch")
    post path, params: { reconciliation_exception_id: other.id, note: "x" }, headers: auth_headers(admin), as: :json
    expect(response).to have_http_status(:not_found)
    expect(StripeService).not_to have_received(:refund_payment)
    expect(warning.reload).to be_open
  end
end
