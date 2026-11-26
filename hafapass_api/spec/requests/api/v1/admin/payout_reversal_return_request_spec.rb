# frozen_string_literal: true

require "rails_helper"

# CodeRabbit 4704013209, through the authenticated admin endpoint. A
# reversal says money that left came back. On an event with a
# never-fulfilled capture it needs the bank's exact return evidence (the
# mechanism the accepted transfer already uses), so a transfer that left is
# never released for another payout on the generic confirmation alone. The
# P4 platform-only proof keeps an unverified reversal (from any release or
# raw SQL) as money still with the organizer. A transfer that never left is
# still recorded failed without return evidence, and events without a
# classified capture keep their existing reversal accounting.
RSpec.describe "Admin payout reversal return evidence", type: :request do
  let(:admin) { create(:user, :admin) }
  let(:profile) { create(:organizer_profile, :verified) }
  let(:organization) { profile.organization }
  let(:event) { create(:event, :completed, organization: organization, organizer_profile: profile) }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 2000) }

  before do
    allow(StripeService).to receive(:verify_payment_context!)
    allow(StripeProcessingFees).to receive(:require_adjustment_review!)
    allow(EmailService).to receive(:send_refund_notification_async)
    allow(Sentry).to receive(:capture_message)
    allow(Sentry).to receive(:capture_exception)
    allow(PayoutGateway).to receive(:submit) do |payout|
      PayoutGateway::Result.new(provider_payout_id: "manual_po_#{payout.id}", status: :processing)
    end
    approved_bank_account!(organization, actor: profile.user, admin: admin)
  end

  def reconcile!(payout, status, provider_payout_id:, **evidence)
    patch "/api/v1/admin/payouts/#{payout.id}", headers: auth_headers(admin), as: :json,
      params: { status: status, provider_payout_id: provider_payout_id,
        evidence: { reference: "Bank transfer record", reason: "Bank confirms the outcome",
          confirmed_at: Time.current.utc.iso8601(6), approved_tax_payee_confirmed: true, **evidence } }
  end

  def payout!(settlement, key)
    PayoutCreator.call(settlement: settlement, actor: admin, idempotency_key: key, amount_cents: 1000)
  end

  def platform_only?(payment)
    ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql_array(["SELECT hafapass_overpaid_platform_only(?)", payment.id])
    )
  end

  # Two payouts approved before the capture was classified (their versions
  # have no $0 line for it): one sent and recorded paid, one never sent. Then the
  # classified capture is over-returned (refund and lost dispute).
  def classified_after_payouts!
    record_card_sale!(event, ticket_type: ticket_type, quantity: 5, processing_fee_cents: 100)
    sent = payout!(Settlements::Finalizer.call(event: event, actor: admin), "rev-sent")
    unsent = payout!(Settlements::Finalizer.call(event: event, actor: admin), "rev-unsent")
    reconcile!(sent, "paid", provider_payout_id: "BANK-REV-1")
    expect(response).to have_http_status(:ok)
    order, payment, capture = classified_capture(items: [[1200, 160, 0, 0]], event: event)
    component = create(:fee_component, order: order, order_item: order.order_items.first, kind: "processing",
      amount_cents: 69, estimated: false, provider_reference: "txn_rev_#{SecureRandom.hex(4)}")
    create(:stripe_fee_evidence, :verified, payment: payment, fee_component: component,
      provider_balance_transaction_id: component.provider_reference)
    ingest_provider_refund!(payment, 1360, id: "re_rev_#{SecureRandom.hex(3)}")
    lose_dispute!(payment, "dp_rev_#{SecureRandom.hex(3)}", amount: 1360)
    Commerce::NeverFulfilledResolution.evaluate!(capture.reload, trigger: "spec")
    expect(ReconciliationException.open.where(payment: payment, code: "never_fulfilled_buyer_overpaid")).to exist
    [payment, sent.reload, unsent.reload]
  end

  it "keeps an unverified reversal defeating P4 and records a reversal only with the bank's exact return" do
    payment, sent, unsent = classified_after_payouts!
    # The never-sent payout is recorded failed, without return evidence.
    reconcile!(unsent, "failed", provider_payout_id: unsent.provider_payout_id, reason: "Never sent to the bank")
    expect(response).to have_http_status(:ok)
    expect(unsent.reload).to be_status_failed
    # Only the sent payout (approved without the capture's line) now defeats
    # the proof.
    expect(platform_only?(payment)).to be(false)
    committed = OrganizationPayoutBalance.available_cents(organization)

    reconcile!(sent, "reversed", provider_payout_id: "BANK-REV-1")
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]).to eq(PayoutReconciler::CLASSIFIED_RETURN_REQUIRED_MESSAGE)
    expect(sent.reload).to be_status_paid
    expect(OrganizationPayoutBalance.available_cents(organization)).to eq(committed)

    # An older release or raw SQL reverses it without evidence: still money
    # with the organizer as far as the proof is concerned.
    ActiveRecord::Base.transaction(requires_new: true) do
      Payout.where(id: sent.id).update_all(status: Payout.statuses[:reversed])
      expect(platform_only?(payment)).to be(false)
      raise ActiveRecord::Rollback
    end

    returned = { return_reference: "RET-REV-1", returned_amount_cents: sent.disbursement_cents }
    reconcile!(sent, "reversed", provider_payout_id: "BANK-REV-1", **returned,
      returned_at: (sent.paid_at - 1).utc.iso8601(6))
    expect(response.parsed_body["error"]).to eq("The return time must be after the transfer left and not in the future")
    reconcile!(sent, "reversed", provider_payout_id: "BANK-REV-1", **returned, returned_amount_cents: 1,
      returned_at: Time.current.utc.iso8601(6))
    expect(response.parsed_body["error"]).to eq("The returned amount must be the full #{sent.disbursement_cents} cents that left")
    reconcile!(sent, "reversed", provider_payout_id: "BANK-OTHER", **returned, returned_at: Time.current.utc.iso8601(6))
    expect(response.parsed_body["error"]).to eq("Keep the original transfer identifier when recording a reversal")
    expect(sent.reload).to be_status_paid

    returned_at = Time.current.utc.iso8601(6)
    reconcile!(sent, "reversed", provider_payout_id: "BANK-REV-1", **returned, returned_at: returned_at)
    expect(response).to have_http_status(:ok)
    expect(sent.reload).to have_attributes(status: "reversed", provider_payout_id: "BANK-REV-1")
    audit = AuditLog.where(auditable: sent, action: "payout.reconciled").order(:id).last
    expect(audit.metadata["verified_return"]).to eq("return_reference" => "RET-REV-1",
      "returned_amount_cents" => sent.disbursement_cents, "returned_at" => returned_at,
      "sent_at" => sent.paid_at.utc.iso8601(6))
    expect(platform_only?(payment)).to be(true)
  end

  it "keeps the existing reversal on an event without a classified capture, verifying evidence when given" do
    record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
    version = Settlements::Finalizer.call(event: event, actor: admin)
    plain = payout!(version, "plain-rev")
    reconcile!(plain, "paid", provider_payout_id: "BANK-PLAIN-1")
    reconcile!(plain, "reversed", provider_payout_id: "BANK-PLAIN-1")
    expect(response).to have_http_status(:ok)
    expect(plain.reload).to be_status_reversed
    expect(AuditLog.where(auditable: plain, action: "payout.reconciled").order(:id).last.metadata).not_to have_key("verified_return")

    evidenced = payout!(Settlements::Finalizer.call(event: event, actor: admin), "plain-rev-2")
    reconcile!(evidenced, "paid", provider_payout_id: "BANK-PLAIN-2")
    reconcile!(evidenced, "reversed", provider_payout_id: "BANK-PLAIN-2", return_reference: "RET-PLAIN-2",
      returned_amount_cents: 1)
    expect(response.parsed_body["error"]).to eq(PayoutReconciler::RETURN_INCOMPLETE_MESSAGE)
    reconcile!(evidenced, "reversed", provider_payout_id: "BANK-PLAIN-2", return_reference: "RET-PLAIN-2",
      returned_amount_cents: evidenced.disbursement_cents, returned_at: Time.current.utc.iso8601(6))
    expect(response).to have_http_status(:ok)
    expect(AuditLog.where(auditable: evidenced, action: "payout.reconciled").order(:id).last.metadata)
      .to have_key("verified_return")
  end
end
