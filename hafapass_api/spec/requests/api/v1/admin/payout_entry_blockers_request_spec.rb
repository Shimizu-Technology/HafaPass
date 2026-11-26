# frozen_string_literal: true

require "rails_helper"

# A2 recheck finding 1 (e49e94d2): the admin payout list must never tell
# finance to send a manual transfer that an entry guard blocks. Each guard
# opens after the placeholder exists (the approved digest still matches), the
# list is reloaded through the authenticated endpoint, and the send
# instruction goes away; paid recording applies the same guard with its dated
# prior-send exception (before the guard: recorded; at or after it: refused),
# and the instruction comes back when the guard is resolved. No money moves:
# the gateway is the manual placeholder.
RSpec.describe "Admin payout dispatch and entry guards", type: :request do
  let(:admin) { create(:user, :admin) }
  let(:profile) { create(:organizer_profile, :verified) }
  let(:organization) { profile.organization }
  let(:event) { create(:event, :completed, organization: organization, organizer_profile: profile) }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 2000) }

  before do
    allow(StripeService).to receive(:verify_payment_context!)
    allow(StripeProcessingFees).to receive(:require_adjustment_review!)
    allow(Sentry).to receive(:capture_message)
    allow(PayoutGateway).to receive(:submit) { |payout| PayoutGateway::Result.new(provider_payout_id: "manual_po_#{payout.id}", status: :processing) }
    approved_bank_account!(organization, actor: profile.user, admin: admin)
  end

  def listed(event_id = nil)
    get "/api/v1/admin/payouts", headers: auth_headers(admin), params: { event_id: event_id }.compact
    expect(response).to have_http_status(:ok)
    response.parsed_body["payouts"].index_by { |payout| payout["id"] }
  end

  def record!(payout, confirmed_at, **evidence)
    patch "/api/v1/admin/payouts/#{payout.id}", headers: auth_headers(admin), as: :json,
      params: { status: "paid", provider_payout_id: "BANK-#{payout.id}",
        evidence: { reference: "Bank statement line", reason: "Transfer confirmed by the bank",
          confirmed_at: confirmed_at.utc.iso8601(6), approved_tax_payee_confirmed: true, **evidence } }
  end

  # A fulfilled sale with an organizer-borne payment-scope second capture on
  # it, classified before the statement is approved: the approved version
  # already has its $0 line, so a processing review that opens later changes
  # no statement line and the digest still matches.
  def sale_with_second_capture!
    order, _item, payment_a = record_card_sale!(event, ticket_type: ticket_type, quantity: 5, processing_fee_cents: 100)
    order.update!(fulfilled_by_payment_id: payment_a.id)
    payment_b = create(:payment, order: order, provider_payment_id: "pi_dispatch_b_#{SecureRandom.hex(3)}",
      amount_cents: 1500, status: :succeeded, succeeded_at: Time.current)
    UnfulfilledCapture.create!(order: order, payment: payment_b, capture_scope: "payment",
      code: "unfulfilled_second_capture", captured_cents: 1500, currency: "usd", proceeds_cents: 1500, fee_cents: 0,
      organizer_fee_cents: 0, tax_cents: 0, processing_bearer: "platform", dispute_fee_bearer: "platform",
      allocation_policy: "item_record", policy_version: Commerce::NeverFulfilledClassification::POLICY_VERSION,
      provenance: "lifecycle")
    # Its verified Stripe fee is deferred (no fee component yet). HåfaPass
    # bears it when the statement is approved; the bearer later turns out to
    # be the organizer's, which opens the review (as in
    # classified_operational_readers_spec's held fee).
    StripeFeeEvidence.create!(payment: payment_b, context_digest: "ctx_dispatch_#{SecureRandom.hex(3)}", status: :review_required,
      provider_charge_id: "ch_dispatch", provider_balance_transaction_id: "txn_dispatch_#{SecureRandom.hex(3)}",
      evidence_digest: "digest_dispatch_#{SecureRandom.hex(3)}", currency: "usd", fee_cents: 74,
      last_error_code: StripeProcessingFees::PAYMENT_SCOPE_DEFERRED_CODE)
    [order, payment_a, payment_b]
  end

  def organizer_bears!(payment_b)
    ActiveRecord::Base.connection.execute("ALTER TABLE never_fulfilled_captures DISABLE TRIGGER never_fulfilled_captures_append_only")
    UnfulfilledCapture.where(payment_id: payment_b.id).update_all(processing_bearer: "organizer")
  ensure
    ActiveRecord::Base.connection.execute("ALTER TABLE never_fulfilled_captures ENABLE TRIGGER never_fulfilled_captures_append_only")
  end

  # Each payout is statement activity, so each is approved on its own version.
  def placeholders!(*keys)
    keys.map do |key|
      PayoutCreator.call(settlement: Settlements::Finalizer.call(event: event, actor: admin), actor: admin,
        idempotency_key: key, amount_cents: 1000)
    end
  end

  it "withdraws the send instruction while the processing review is open, records only a transfer sent before it, and restores it on resolution" do
    order, _payment_a, payment_b = sale_with_second_capture!
    before_review, at_review, after_review, unsent = placeholders!("rev-before", "rev-at", "rev-after", "rev-unsent")
    # A placeholder payout on an unrelated event keeps its own readiness.
    other_event = create(:event, :completed, organization: organization, organizer_profile: profile)
    record_card_sale!(other_event, ticket_type: create(:ticket_type, event: other_event, price_cents: 2000), quantity: 2)
    unaffected = PayoutCreator.call(settlement: Settlements::Finalizer.call(event: other_event, actor: admin), actor: admin,
      idempotency_key: "rev-unaffected", amount_cents: 500)

    payouts = listed
    expect([before_review, at_review, after_review, unsent, unaffected].map { |payout| payouts.fetch(payout.id)["dispatch"] })
      .to all(include("actionable" => true, "placeholder" => true, "reasons" => []))

    sleep 0.02
    sent_time = Time.current
    sleep 0.02
    organizer_bears!(payment_b)
    review = ReconciliationException.create!(order: order, payment: payment_b, code: StripeProcessingFees::REVIEW_CODE)
    opened = review.reload.created_at
    expect(PayoutEntryGuard.stale?(unsent)).to be(false)

    payouts = listed
    [before_review, at_review, after_review, unsent].each do |payout|
      expect(payouts.fetch(payout.id)["dispatch"]).to include("actionable" => false, "placeholder" => true,
        "reasons" => ["organizer_processing"], "messages" => [PayoutEntryGuard::DISPATCH_REASONS.fetch("organizer_processing")])
    end
    expect(payouts.fetch(unaffected.id)["dispatch"]).to include("actionable" => true, "reasons" => [])

    # Paid recording: the dated prior-send exception, before / at / after.
    record!(at_review, opened, sent_before_hold_confirmed: true)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]).to eq(Commerce::NeverFulfilledPayoutHold::ORGANIZER_PROCESSING_PAID_MESSAGE)
    record!(after_review, opened + 1.second, sent_before_hold_confirmed: true)
    expect(response).to have_http_status(:unprocessable_content)
    record!(before_review, sent_time)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]).to eq(Commerce::NeverFulfilledPayoutHold::ORGANIZER_PROCESSING_PAID_MESSAGE)
    record!(before_review, sent_time, sent_before_hold_confirmed: true)
    expect(response).to have_http_status(:ok)
    expect(before_review.reload).to have_attributes(status: "paid", provider_payout_id: "BANK-#{before_review.id}")
    expect(AuditLog.where(auditable: before_review, action: "payout.reconciled").sole.metadata)
      .to include("organizer_processing_review_started_at" => opened.utc.iso8601(6))
    expect([at_review, after_review, unsent].map { |payout| payout.reload.status }).to all(eq("processing"))
    # The placeholder is never treated as money: it cannot be recorded paid.
    patch "/api/v1/admin/payouts/#{unsent.id}", headers: auth_headers(admin), as: :json,
      params: { status: "paid", evidence: { reference: "Bank", reason: "Placeholder only", confirmed_at: sent_time.utc.iso8601(6),
        sent_before_hold_confirmed: true, approved_tax_payee_confirmed: true } }
    expect(response.parsed_body["error"]).to eq("A real provider or bank transfer identifier is required to record payment")

    # Ordinary resolution: finance closes the review, and the still-intended
    # transfers are actionable again.
    review.update!(status: :resolved, resolved_at: Time.current)
    payouts = listed
    [at_review, after_review, unsent].each do |payout|
      expect(payouts.fetch(payout.id)["dispatch"]).to include("actionable" => true, "reasons" => [])
    end
    expect(payouts.fetch(before_review.id)["dispatch"]).to be_nil
  end

  it "withdraws it while a buyer refund is unresolved or the repayment hold is open, and after an approval goes stale" do
    order, item, payment_a = record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
    payout, = placeholders!("liab-1")
    expect(listed.fetch(payout.id)["dispatch"]).to include("actionable" => true)

    failed = create(:refund, order: order, payment: payment_a, amount_cents: 500, status: :failed)
    create(:refund_item, refund: failed, order_item: item, amount_cents: 500, organizer_proceeds_cents: 500, quantity: 1)
    listing = listed.fetch(payout.id)
    expect(listing["dispatch"]).to include("actionable" => false, "reasons" => ["refund_liabilities"])
    expect(listing["outstanding_buyer_balance_cents"]).to eq(500)
    # Resolved: the refund was retried and succeeded (an unaffected event's
    # ordinary refund has no statement cutoff of its own).
    failed.update!(status: :succeeded, succeeded_at: Time.current)
    expect(listed.fetch(payout.id)["dispatch"]).to include("actionable" => true)

    exception = ReconciliationException.create!(order: order, payment: payment_a, code: "late_payment_success_after_hold_expiry")
    expect(listed.fetch(payout.id)["dispatch"]).to include("actionable" => false, "reasons" => include("hold"))
    exception.update!(status: :resolved, resolved_at: Time.current)
    expect(listed.fetch(payout.id)["dispatch"]).to include("actionable" => true)

    # Stale approval: the bank destination on file changed after approval
    # (older data; edits are blocked while a transfer is in flight).
    account = payout.connected_account
    account.update_columns(payout_details: account.payout_details.merge("bank_name" => "Another Fictional Bank"))
    expect(listed.fetch(payout.id)["dispatch"]).to include("actionable" => false, "reasons" => include("payee_changed"))
  end
end
