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

  # A2 recheck finding 1 (7664e143): the database enforces the same boundary
  # for every writer (A1 during the overlap or after a code rollback, raw
  # SQL), on a version that already has the capture's $0 line (where the P4
  # proof does not look). Deferred to commit, so the exact return the same
  # transaction records counts; SET CONSTRAINTS ... IMMEDIATE runs that
  # commit-time check inside the spec's transaction.
  def commit_check!
    ActiveRecord::Base.connection.execute("SET CONSTRAINTS payouts_reversal_return_check, " \
      "payouts_reversal_return_check_on_insert IMMEDIATE")
  end

  # CodeRabbit 4704933005: the fence reads the durable proof
  # (payout_return_proofs), never audit metadata, so an exact audit alone no
  # longer counts; `proof` writes the proof row as the current release does.
  def raw_reversal(payout, metadata = nil, action: "payout.reconciled", proof: nil)
    ActiveRecord::Base.transaction(requires_new: true) do
      Payout.where(id: payout.id).update_all(status: Payout.statuses[:reversed])
      if metadata
        AuditLog.create!(auditable: payout, organization: payout.organization, action: action, occurred_at: Time.current,
          before_data: { "status" => "paid" }, after_data: { "status" => "reversed" }, metadata: metadata)
      end
      raw_return_proof!(payout, **proof) if proof
      commit_check!
      raise ActiveRecord::Rollback
    end
    :accepted
  rescue ActiveRecord::StatementInvalid => e
    e.message[/Payout reversal fence[^\n]*/] || raise
  end

  it "refuses every unverified reversal on an affected event at commit, even on a version with the $0 line" do
    record_card_sale!(event, ticket_type: ticket_type, quantity: 5, processing_fee_cents: 100)
    order, payment, = classified_capture(items: [[1200, 160, 0, 0]], event: event)
    component = create(:fee_component, order: order, order_item: order.order_items.first, kind: "processing",
      amount_cents: 69, estimated: false, provider_reference: "txn_rev_db_#{SecureRandom.hex(4)}")
    create(:stripe_fee_evidence, :verified, payment: payment, fee_component: component,
      provider_balance_transaction_id: component.provider_reference)
    sent = payout!(Settlements::Finalizer.call(event: event, actor: admin), "rev-db")
    expect(PayoutEntryGuard.restated_at(sent.settlement)).to be_nil
    reconcile!(sent, "paid", provider_payout_id: "BANK-REV-DB")
    expect(response).to have_http_status(:ok)
    sent.reload
    available = OrganizationPayoutBalance.available_cents(organization)
    exact = { "return_reference" => "RET-DB-1", "returned_amount_cents" => sent.disbursement_cents,
      "returned_at" => Time.current.utc.iso8601(6), "sent_at" => sent.paid_at.utc.iso8601(6) }
    fence = /\APayout reversal fence: payout #{sent.id} is on an event with a never-fulfilled capture/

    # The old release's generic reversal (what A1 writes), raw SQL, a return
    # key alone, the wrong amount, a blank reference or a different action.
    expect(raw_reversal(sent)).to match(fence)
    expect(raw_reversal(sent, { "reconciliation" => { "reference" => "Bank", "reason" => "Returned" } })).to match(fence)
    expect(raw_reversal(sent, { "verified_return" => { "return_reference" => "RET-DB-1" } })).to match(fence)
    expect(raw_reversal(sent, { "verified_return" => exact.merge("returned_amount_cents" => sent.disbursement_cents - 1) }))
      .to match(fence)
    expect(raw_reversal(sent, { "verified_return" => exact.merge("return_reference" => " ") })).to match(fence)
    expect(raw_reversal(sent, { "verified_return" => exact.merge("returned_at" => "soon") })).to match(fence)
    expect(raw_reversal(sent, { "verified_return" => exact }, action: "payout.reversed")).to match(fence)
    # A reversal inserted directly is checked the same way.
    expect do
      ActiveRecord::Base.transaction(requires_new: true) do
        FinancialIntegrity.with_settlement_reader do
          Payout.insert_all!([sent.attributes.except("id", "created_at", "updated_at")
            .merge("status" => Payout.statuses[:reversed], "idempotency_key" => "rev-db-insert", "provider_payout_id" => nil)])
        end
        commit_check!
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /Payout reversal fence/)
    expect(sent.reload).to be_status_paid
    expect(OrganizationPayoutBalance.available_cents(organization)).to eq(available)
    expect do
      PayoutCreator.call(settlement: Settlements::Finalizer.call(event: event, actor: admin), actor: admin, idempotency_key: "rev-db-fresh", amount_cents: available + 1000)
    end.to raise_error(PayoutCreator::PayoutError, /available balance/)

    # The exact audit alone is not the durable proof; a proof row from a
    # writer that does not name itself as the current reconciler is refused.
    expect(raw_reversal(sent, { "verified_return" => exact })).to match(fence)
    expect do
      raw_reversal(sent, nil, proof: { returned_at: Time.current, sent_at: sent.paid_at, authorized: false })
    end.to raise_error(ActiveRecord::StatementInvalid, /Payout return proof: record the return from the current release/)
    expect do
      raw_reversal(sent, nil, proof: { returned_at: Time.current, sent_at: sent.paid_at, amount: sent.disbursement_cents - 1 })
    end.to raise_error(ActiveRecord::StatementInvalid, /full amount that left/)
    expect do
      raw_reversal(sent, nil, proof: { returned_at: sent.paid_at - 1, sent_at: sent.paid_at })
    end.to raise_error(ActiveRecord::StatementInvalid, /return time after the transfer left/)
    # The exact durable proof written in the same transaction passes.
    expect(raw_reversal(sent, { "verified_return" => exact }, proof: { returned_at: Time.current, sent_at: sent.paid_at }))
      .to eq(:accepted)
    expect(sent.reload).to be_status_paid

    # A2's own path, with the bank's return, through the commit-time check.
    reconcile!(sent, "reversed", provider_payout_id: "BANK-REV-DB", return_reference: "RET-DB-1",
      returned_amount_cents: sent.disbursement_cents, returned_at: Time.current.utc.iso8601(6))
    expect(response).to have_http_status(:ok)
    expect { commit_check! }.not_to raise_error
    expect(sent.reload).to be_status_reversed
    expect(OrganizationPayoutBalance.available_cents(organization)).to eq(available + 1000)
  end

  it "keeps the existing reversal on an event without a classified capture, verifying evidence when given" do
    record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
    version = Settlements::Finalizer.call(event: event, actor: admin)
    plain = payout!(version, "plain-rev")
    reconcile!(plain, "paid", provider_payout_id: "BANK-PLAIN-1")
    reconcile!(plain, "reversed", provider_payout_id: "BANK-PLAIN-1")
    expect(response).to have_http_status(:ok)
    expect { commit_check! }.not_to raise_error
    expect(plain.reload).to be_status_reversed
    # Raw SQL on an ordinary event is unaffected too.
    other = payout!(Settlements::Finalizer.call(event: event, actor: admin), "plain-rev-raw")
    reconcile!(other, "paid", provider_payout_id: "BANK-PLAIN-RAW")
    expect(raw_reversal(other.reload)).to eq(:accepted)
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
