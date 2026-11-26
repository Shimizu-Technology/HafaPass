# frozen_string_literal: true

require "rails_helper"

# A2 review finding 1 (17324039): the authenticated operator request for the
# exceptional, API-only prior-send confirmation. An admin records a manual
# transfer submitted and sent before an ordinary refund changed the approved
# statement; one sent after it is refused; an undatable change needs the
# finance disposition fields. No money moves: the gateway is the manual
# placeholder.
RSpec.describe "Admin payout recording after a statement change", type: :request do
  let(:admin) { create(:user, :admin) }
  let(:profile) { create(:organizer_profile, :verified) }
  let(:organization) { profile.organization }
  let(:event) { create(:event, :completed, organization: organization, organizer_profile: profile) }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 2000) }

  before do
    allow(StripeProcessingFees).to receive(:require_adjustment_review!)
    allow(Sentry).to receive(:capture_message)
    allow(PayoutGateway).to receive(:submit) { |payout| PayoutGateway::Result.new(provider_payout_id: "manual_po_#{payout.id}", status: :processing) }
    approved_bank_account!(organization, actor: profile.user, admin: admin)
  end

  def submitted!(key)
    PayoutCreator.call(settlement: Settlements::Finalizer.call(event: event, actor: admin), actor: admin, idempotency_key: key,
      amount_cents: 1000)
  end

  def classified!
    classified_capture(items: [[1200, 160, 0, 0]], event: event).then do |classified, payment, _capture|
      component = create(:fee_component, order: classified, order_item: classified.order_items.first, kind: "processing",
        amount_cents: 69, estimated: false, provider_reference: "txn_req_#{SecureRandom.hex(4)}")
      create(:stripe_fee_evidence, :verified, payment: payment, fee_component: component,
        provider_balance_transaction_id: component.provider_reference)
    end
  end

  def record!(payout, confirmed_at, user: admin, **evidence)
    patch "/api/v1/admin/payouts/#{payout.id}", headers: auth_headers(user), as: :json,
      params: { status: "paid", provider_payout_id: "BANK-#{payout.id}",
        evidence: { reference: "Bank statement line", reason: "Transfer confirmed by the bank",
          confirmed_at: confirmed_at.utc.iso8601(6), approved_tax_payee_confirmed: true, **evidence } }
  end

  it "records a genuine pre-change transfer, refuses a later one and a non-admin, and lists the dispatch state" do
    order, item, capture = record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
    classified!
    sent = submitted!("req-sent")
    late = submitted!("req-late")
    sleep 0.02
    pre = Time.current
    sleep 0.02
    record_card_refund!(order, item, capture, proceeds_cents: 500)

    get "/api/v1/admin/payouts", headers: auth_headers(admin)
    expect(response.parsed_body["payouts"].map { |payout| payout["dispatch"] })
      .to all(include("actionable" => false, "placeholder" => true, "reasons" => ["statement_changed"]))

    record!(late, Time.current, sent_before_restatement_confirmed: true)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]).to eq(PayoutEntryGuard::STALE_PAID_MESSAGE)
    record!(sent, pre, user: create(:user), sent_before_restatement_confirmed: true)
    expect(response).to have_http_status(:forbidden)

    record!(sent, pre, sent_before_restatement_confirmed: true)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("status" => "paid", "provider_payout_id" => "BANK-#{sent.id}")
    expect(sent.reload.custody_determination).to be_present
    expect(late.reload).to be_status_processing
  end

  it "accepts the disposition fields only when the change cannot be dated" do
    record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
    classified!
    sent = submitted!("req-undated")
    sleep 0.02
    pre = Time.current
    component = FeeComponent.where(order_id: event.orders.where(never_fulfilled_at: nil).select(:id), kind: "processing").first
    FeeComponent.where(id: component.id).update_all(amount_cents: component.amount_cents + 5)

    record!(sent, pre, sent_before_restatement_confirmed: true)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]).to eq(PayoutEntryGuard::DISPOSITION_MESSAGE)
    record!(sent, pre, sent_before_restatement_confirmed: true,
      stale_disposition_reason: "Bank statement shows the transfer left before the fee correction",
      stale_disposition_reference: "FIN-11")
    expect(response).to have_http_status(:ok)
    expect(AuditLog.where(auditable: sent, action: "payout.stale_statement_disposition").sole.metadata)
      .to include("reference" => "FIN-11")
  end
end
