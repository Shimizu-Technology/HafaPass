# frozen_string_literal: true

require "rails_helper"

# CodeRabbit review of 7664e143, money and evidence findings, through the
# authenticated admin endpoints where finance acts:
#   4704932928 a provider's paid result on a payout a cancellation hold held
#              while the gateway call ran is an accepted transfer: kept held
#              and committed, never failed or re-spent;
#   4704932935 a reversal keeps the stored real transfer identifier, also
#              after a conflicting provider result reopened a paid payout;
#   4704932964 a returned check is the audited amount actually issued;
#   4704932978 an accepted return is compared with the provider's paid time;
#   4704933005 the exact return is a durable, non-personal proof that
#              survives audit redaction (database and API);
#   4704932911 a reversal already recorded without it gets the bank's return
#              attached, idempotently, without changing the payout;
#   4704933000 a payout's settlement version is fixed once its custody is.
RSpec.describe "Admin payout return proof", type: :request do
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

  def reconcile!(payout, status, provider_payout_id: payout.reload.provider_payout_id, **evidence)
    patch "/api/v1/admin/payouts/#{payout.id}", headers: auth_headers(admin), as: :json,
      params: { status: status, provider_payout_id: provider_payout_id,
        evidence: { reference: "Bank transfer record", reason: "Bank confirms the outcome",
          confirmed_at: Time.current.utc.iso8601(6), approved_tax_payee_confirmed: true, **evidence } }
  end

  def attach!(payout, user: admin, provider_payout_id: nil, **evidence)
    post "/api/v1/admin/payouts/#{payout.id}/return_evidence", headers: auth_headers(user), as: :json,
      params: { provider_payout_id: provider_payout_id,
        evidence: { reference: "Bank return statement", reason: "Bank statement shows the full return",
          confirmed_at: Time.current.utc.iso8601(6), **evidence } }.compact
  end

  def payout!(key, amount_cents: 1000, settlement: Settlements::Finalizer.call(event: event, actor: admin))
    PayoutCreator.call(settlement: settlement, actor: admin, idempotency_key: key, amount_cents: amount_cents)
  end

  def provider_result!(payout, **attributes)
    PayoutCreator.new(settlement: payout.settlement, actor: admin, idempotency_key: payout.idempotency_key)
      .send(:record_submission_outcome!, payout, initiated_at: Time.current, **attributes)
  end

  def available
    OrganizationPayoutBalance.available_cents(organization)
  end

  def listing(payout)
    get "/api/v1/admin/payouts", headers: auth_headers(admin)
    response.parsed_body["payouts"].find { |row| row["id"] == payout.id }
  end

  def platform_only?(payment)
    ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql_array(["SELECT hafapass_overpaid_platform_only(?)", payment.id])
    )
  end

  def return_verified?(payout)
    ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql_array(["SELECT hafapass_payout_return_verified(?)", payout.id])
    )
  end

  def cpa_row
    now = Time.current.in_time_zone("Pacific/Guam")
    CpaMonthlyReport.new(now.year, now.month).report.then do |report|
      [report, report[:rows].find { |entry| entry[:event_id] == event.id }]
    end
  end

  # A classified capture on the event, over-returned after the given payouts
  # (their versions have no $0 line for it).
  def over_returned_capture!
    order, payment, capture = classified_capture(items: [[1200, 160, 0, 0]], event: event)
    component = create(:fee_component, order: order, order_item: order.order_items.first, kind: "processing",
      amount_cents: 69, estimated: false, provider_reference: "txn_proof_#{SecureRandom.hex(4)}")
    create(:stripe_fee_evidence, :verified, payment: payment, fee_component: component,
      provider_balance_transaction_id: component.provider_reference)
    ingest_provider_refund!(payment, 1360, id: "re_proof_#{SecureRandom.hex(3)}")
    lose_dispute!(payment, "dp_proof_#{SecureRandom.hex(3)}", amount: 1360)
    Commerce::NeverFulfilledResolution.evaluate!(capture.reload, trigger: "spec")
    expect(ReconciliationException.open.where(payment: payment, code: "never_fulfilled_buyer_overpaid")).to exist
    payment
  end

  describe "a provider's paid result while a cancellation hold holds the payout (4704932928)" do
    it "keeps it an accepted transfer: held, committed, never failed, released or re-spent" do
      record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
      settlement = Settlements::Finalizer.call(event: event, actor: admin)
      before_payout = available
      expect(before_payout).to be > 1000
      calls = 0
      allow(PayoutGateway).to receive(:submit) do |_payout|
        calls += 1
        # The hold commits after the submission locks are released, while
        # the gateway call is in flight.
        EventCancellationRefunds.hold_payouts!(event, actor: admin)
        PayoutGateway::Result.new(provider_payout_id: "BANK-HELD-1", status: :paid)
      end
      payout = payout!("held-paid-1", settlement: settlement)
      expect(payout.reload).to have_attributes(status: "held", held_from_status: "processing", paid_at: nil,
        provider_payout_id: "BANK-HELD-1", failure_code: "provider_result_conflict", amount_cents: 1000)
      conflict = AuditLog.where(auditable: payout, action: "payout.provider_result_conflict").sole
      expect(conflict.metadata).to include("conflict_reason" => PayoutCreator::PAID_REFUSED_REASON,
        "entry_blocker" => "cancellation_hold", "disbursement_cents" => payout.disbursement_cents)
      expect(conflict.metadata["provider_paid_at"]).to be_present
      expect(PayoutCreator.provider_accepted?(payout)).to be(true)

      # Its amount stays committed (and the open conflict freezes the
      # organization's balance): no fresh key can send it again, and the
      # hold cannot be released while the conflict is open.
      expect(available).to eq(0)
      allow(PayoutGateway).to receive(:submit) { |next_payout| PayoutGateway::Result.new(provider_payout_id: "manual_po_#{next_payout.id}", status: :processing) }
      expect { payout!("held-paid-fresh", amount_cents: 1000) }
        .to raise_error(PayoutCreator::PayoutError, /available balance/)
      expect { PayoutHoldRelease.call(payout: payout, actor: admin) }
        .to raise_error(PayoutHoldRelease::ReleaseError, /provider result conflict/)
      expect(calls).to eq(1)

      # A later provider result never downgrades it.
      provider_result!(payout, status: :failed, provider_payout_id: "BANK-HELD-1", failure_code: "provider_returned")
      expect(payout.reload).to have_attributes(status: "held", failure_code: "provider_result_conflict")
      expect(AuditLog.where(auditable: payout, action: "payout.late_result_ignored").sole.metadata)
        .to include("accepted_transfer" => true)

      # Never recorded failed (which would release it) or ordinary paid.
      reconcile!(payout, "failed", conflict_audit_id: conflict.id)
      expect(response.parsed_body["error"]).to eq(PayoutReconciler::ACCEPTED_NOT_FAILED_MESSAGE)
      reconcile!(payout, "paid", conflict_audit_id: conflict.id, sent_before_cancellation_confirmed: true,
        cancellation_payout_reason: "Sent before the hold")
      expect(response.parsed_body["error"]).to eq(PayoutReconciler::ACCEPTED_NOT_PAID_MESSAGE)
      expect(listing(payout)).to include("provider_accepted" => true, "allowed_outcomes" => ["reversed"])

      # Finance records the acceptance (cash out, once), then the exact return.
      reconcile!(payout, "accepted_transfer", conflict_audit_id: conflict.id)
      expect(response).to have_http_status(:ok)
      expect(payout.reload).to be_status_held
      report, row = cpa_row
      expect(report[:accepted_transfers].map { |entry| entry[:payout_id] }).to eq([payout.id])
      expect(row).to include(organizer_payouts_made_cents: 1000, payout_reversals_cents: 0)
      expect(available).to eq(0)

      reconcile!(payout, "reversed", conflict_audit_id: conflict.id, return_reference: "RET-HELD-1",
        returned_amount_cents: payout.disbursement_cents, returned_at: Time.current.utc.iso8601(6))
      expect(response).to have_http_status(:ok)
      expect(payout.reload).to have_attributes(status: "reversed", provider_payout_id: "BANK-HELD-1", paid_at: nil)
      expect(payout.return_proof).to have_attributes(kind: "accepted_transfer_return",
        returned_amount_cents: payout.disbursement_cents, sent_at: Time.iso8601(conflict.metadata["provider_paid_at"]))
      _, row = cpa_row
      expect(row).to include(organizer_payouts_made_cents: 1000, payout_reversals_cents: 1000)
      expect(available).to eq(before_payout)
    end

    it "keeps the stock manual gateway's in-flight result an ordinary conflict that can still be recorded failed" do
      record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
      settlement = Settlements::Finalizer.call(event: event, actor: admin)
      before_payout = available
      allow(PayoutGateway).to receive(:submit) do |payout|
        EventCancellationRefunds.hold_payouts!(event, actor: admin)
        PayoutGateway::Result.new(provider_payout_id: "manual_po_#{payout.id}", status: :processing)
      end
      payout = payout!("held-manual-1", settlement: settlement)
      expect(payout.reload).to have_attributes(status: "held", held_from_status: "pending",
        failure_code: "provider_result_conflict")
      expect(PayoutCreator.provider_accepted?(payout)).to be(false)
      conflict = AuditLog.where(auditable: payout, action: "payout.provider_result_conflict").sole
      expect(conflict.metadata).not_to have_key("conflict_reason")

      reconcile!(payout, "failed", conflict_audit_id: conflict.id, reason: "Finance never sent the transfer")
      expect(response).to have_http_status(:ok)
      expect(payout.reload).to be_status_failed
      expect(available).to eq(before_payout)
    end

    it "compares the return with the provider's paid time, not the later conflict recording (4704932978)" do
      record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
      payout = payout!("held-late-1")
      # Submitted 40 minutes ago (the request and its submission).
      Payout.where(id: payout.id).update_all(created_at: 40.minutes.ago, initiated_at: 40.minutes.ago)
      EventCancellationRefunds.hold_payouts!(event, actor: admin)
      expect(payout.reload).to have_attributes(status: "held", held_from_status: "processing")
      provider_paid_at = 20.minutes.ago
      provider_result!(payout, status: :paid, provider_payout_id: "BANK-LATE-1", paid_at: provider_paid_at)
      conflict = AuditLog.where(auditable: payout, action: "payout.provider_result_conflict")
        .where("metadata->>'conflict_reason' = ?", PayoutCreator::PAID_REFUSED_REASON).sole
      expect(conflict.occurred_at).to be > provider_paid_at + 15.minutes
      reconcile!(payout, "accepted_transfer", conflict_audit_id: conflict.id)
      expect(response).to have_http_status(:ok)

      returned = { conflict_audit_id: conflict.id, return_reference: "RET-LATE-1",
        returned_amount_cents: payout.disbursement_cents }
      reconcile!(payout, "reversed", **returned, returned_at: (provider_paid_at - 1.minute).utc.iso8601(6))
      expect(response.parsed_body["error"]).to match(/after the provider accepted/)
      # Dated after the provider paid it and before the conflict was recorded.
      reconcile!(payout, "reversed", **returned, returned_at: 15.minutes.ago.utc.iso8601(6))
      expect(response).to have_http_status(:ok)
      expect(payout.reload).to be_status_reversed
      expect(payout.return_proof.sent_at).to be_within(0.001.seconds).of(provider_paid_at)
    end
  end

  it "keeps the stored real transfer identifier after a conflicting provider result reopens it (4704932935)" do
    record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
    payout = payout!("conflict-id-1")
    reconcile!(payout, "paid", provider_payout_id: "BANK-X-1")
    expect(response).to have_http_status(:ok)
    committed = available
    provider_result!(payout, status: :paid, provider_payout_id: "BANK-Y-1")
    expect(available).to eq(0)
    expect(payout.reload).to have_attributes(status: "processing", provider_payout_id: "BANK-X-1",
      failure_code: "provider_result_conflict")
    conflict = AuditLog.where(auditable: payout, action: "payout.provider_result_conflict").sole
    exact = { conflict_audit_id: conflict.id, return_reference: "RET-Y-1", returned_amount_cents: payout.disbursement_cents,
      returned_at: Time.current.utc.iso8601(6) }

    reconcile!(payout, "reversed", provider_payout_id: "BANK-Y-1", **exact)
    expect(response.parsed_body["error"]).to eq("Keep the original transfer identifier when recording a reversal")
    reconcile!(payout, "reversed", provider_payout_id: "BANK-Y-1", conflict_audit_id: conflict.id)
    expect(response.parsed_body["error"]).to eq("Keep the original transfer identifier when recording a reversal")
    expect(payout.reload).to have_attributes(status: "processing", provider_payout_id: "BANK-X-1")
    expect(available).to eq(0)

    reconcile!(payout, "reversed", provider_payout_id: "BANK-X-1", **exact)
    expect(response).to have_http_status(:ok)
    expect(payout.reload).to have_attributes(status: "reversed", provider_payout_id: "BANK-X-1")
    expect(payout.return_proof).to have_attributes(kind: "verified_return", sent_at: payout.paid_at)
    expect(available).to eq(committed + 1000)
  end

  describe "a returned check (4704932964)" do
    let(:account) do
      create(:connected_account, organization: organization, provider: "check", provider_account_id: nil,
        payout_details: { "payee_name" => "Ambros Inc.", "delivery_method" => "pickup", "pickup_note" => "Front desk" })
    end
    let!(:check) do
      create(:payout, organization: organization, event: event, connected_account: account, amount_cents: 1000,
        settlement: create(:settlement, organization: organization, event: event),
        status: :processing, provider_payout_id: "manual_po_check_fixture", created_at: 1.hour.ago,
        payee_snapshot: account.check_payee, payee_approval_digest: account.readiness_state_digest)
    end

    it "is the audited amount actually issued, in the application and the database" do
      post "/api/v1/admin/payouts/#{check.id}/check_amount_adjustment", headers: auth_headers(admin),
        params: { actual_check_amount_cents: 900, reason: "Check register shows the issued amount" }
      expect(response).to have_http_status(:ok)
      reconcile!(check, "paid", provider_payout_id: "Check 1050", actual_check_amount_cents: 900,
        confirmed_at: 10.minutes.ago.utc.iso8601(6))
      expect(response).to have_http_status(:ok)
      expect(check.reload).to have_attributes(status: "paid", disbursement_cents: 1000, confirmed_check_amount_cents: 900)

      returned = { return_reference: "RET-CHECK-1", returned_at: Time.current.utc.iso8601(6) }
      reconcile!(check, "reversed", provider_payout_id: "Check 1050", **returned, returned_amount_cents: 1000)
      expect(response.parsed_body["error"]).to eq("The returned amount must be the full 900 cents that left")
      expect do
        ActiveRecord::Base.transaction(requires_new: true) do
          raw_return_proof!(check, amount: 1000, returned_at: Time.current, sent_at: check.paid_at)
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /full amount that left/)

      reconcile!(check, "reversed", provider_payout_id: "Check 1050", **returned, returned_amount_cents: 900)
      expect(response).to have_http_status(:ok)
      expect(check.reload).to have_attributes(status: "reversed", amount_cents: 1000, disbursement_cents: 1000)
      expect(check.return_proof).to have_attributes(returned_amount_cents: 900, kind: "verified_return")
      expect(return_verified?(check)).to be(true)
      expect(check.payout_check_adjustments.sum(:amount_cents)).to eq(-100)
      expect(PayoutLineAllocation.where(payout: check).count).to eq(check.payout_line_allocations.count)
    end
  end

  it "keeps the exact return as a durable non-personal proof through audit redaction (4704933005)" do
    record_card_sale!(event, ticket_type: ticket_type, quantity: 5, processing_fee_cents: 100)
    sent = payout!("durable-1")
    reconcile!(sent, "paid", provider_payout_id: "BANK-DUR-1")
    payment = over_returned_capture!
    expect(platform_only?(payment)).to be(false)

    returned_at = Time.current.utc.iso8601(6)
    reconcile!(sent, "reversed", provider_payout_id: "BANK-DUR-1", return_reference: "RET-DUR-0042",
      returned_amount_cents: sent.reload.disbursement_cents, returned_at: returned_at)
    expect(response).to have_http_status(:ok)
    proof = sent.reload.return_proof
    expect(proof).to have_attributes(kind: "verified_return", returned_amount_cents: 1000,
      return_reference_digest: Digest::SHA256.hexdigest("RET-DUR-0042"), sent_at: sent.paid_at)
    expect(proof.returned_at).to eq(Time.iso8601(returned_at))
    expect(proof.attributes.values.map(&:to_s).join(" ")).not_to include("RET-DUR")
    expect { proof.update!(returned_amount_cents: 1) }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect do
      ActiveRecord::Base.transaction(requires_new: true) { PayoutReturnProof.where(id: proof.id).update_all(returned_amount_cents: 1) }
    end.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    expect(platform_only?(payment)).to be(true)
    _, row_before = cpa_row

    # Retention anonymizes every audit row of the payout.
    AuditLog.redact!(AuditLog.where(auditable: sent), { ip_address: nil, before_data: {}, after_data: {}, metadata: {},
      retention_anonymized_at: Time.current, updated_at: Time.current })
    expect(AuditLog.where(auditable: sent, action: "payout.reconciled").pluck(:metadata).uniq).to eq([{}])
    expect(return_verified?(sent)).to be(true)
    expect(platform_only?(payment)).to be(true)
    _, row_after = cpa_row
    expect(row_after).to include(organizer_payouts_made_cents: row_before[:organizer_payouts_made_cents],
      payout_reversals_cents: row_before[:payout_reversals_cents])
    expect(listing(sent)).to include("return_evidence_required" => false,
      "return_proof" => { "kind" => "verified_return", "returned_amount_cents" => 1000, "returned_at" => returned_at,
        "sent_at" => sent.paid_at.utc.iso8601(6), "recorded_at" => proof.recorded_at.utc.iso8601(6) })
  end

  describe "a reversal recorded before its event had a classified capture (4704932911)" do
    def reversed_then_classified!
      record_card_sale!(event, ticket_type: ticket_type, quantity: 5, processing_fee_cents: 100)
      sent = payout!("legacy-rev-1")
      reconcile!(sent, "paid", provider_payout_id: "BANK-LEG-1")
      expect(response).to have_http_status(:ok)
      reconcile!(sent, "reversed", provider_payout_id: "BANK-LEG-1", reason: "Bank returned the transfer")
      expect(response).to have_http_status(:ok)
      expect(sent.reload).to have_attributes(status: "reversed", provider_payout_id: "BANK-LEG-1")
      expect(sent.paid_at).to be_present
      expect(sent.return_proof).to be_nil
      [sent, over_returned_capture!]
    end

    it "attaches the bank's exact return without changing the payout, idempotently, and lifts the proof" do
      sent, payment = reversed_then_classified!
      # Unknown funds are never counted as returned: the event stays held.
      expect(platform_only?(payment)).to be(false)
      expect(listing(sent)).to include("status" => "reversed", "return_evidence_required" => true, "return_proof" => nil)
      frozen = sent.attributes.slice("status", "amount_cents", "withheld_cents", "paid_at", "provider_payout_id", "updated_at")
      reversal = AuditLog.where(auditable: sent, action: "payout.reconciled").order(:id).last
      report_before, row_before = cpa_row

      attach!(sent, user: create(:user), return_reference: "RET-LEG-1", returned_amount_cents: 1000,
        returned_at: Time.current.utc.iso8601(6))
      expect(response).to have_http_status(:forbidden)
      exact = { return_reference: "RET-LEG-1", returned_amount_cents: 1000, returned_at: Time.current.utc.iso8601(6) }
      attach!(sent, **exact, returned_amount_cents: 999)
      expect(response.parsed_body["error"]).to eq("The returned amount must be the full 1000 cents that left")
      attach!(sent, **exact, returned_at: (sent.paid_at - 1).utc.iso8601(6))
      expect(response.parsed_body["error"]).to eq("The return time must be after the transfer left and not in the future")
      attach!(sent, **exact, provider_payout_id: "BANK-OTHER")
      expect(response.parsed_body["error"]).to eq("Keep the original transfer identifier when recording a reversal")
      attach!(sent, **exact.except(:returned_at))
      expect(response.parsed_body["error"]).to eq(PayoutReconciler::RETURN_INCOMPLETE_MESSAGE)
      expect(PayoutReturnProof.where(payout: sent)).to be_empty

      confirmed_at = Time.current.utc.iso8601(6)
      2.times do
        attach!(sent, **exact, confirmed_at: confirmed_at)
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to include("status" => "reversed",
          "return_proof" => include("kind" => "attached_return", "returned_amount_cents" => 1000))
      end
      attach!(sent, **exact, return_reference: "RET-LEG-2", confirmed_at: confirmed_at)
      expect(response.parsed_body["error"]).to eq("This payout's return was already recorded with different evidence")

      expect(sent.reload.attributes.slice(*frozen.keys)).to eq(frozen)
      expect(PayoutReturnProof.where(payout: sent).count).to eq(1)
      attached = AuditLog.where(auditable: sent, action: PayoutReconciler::RETURN_EVIDENCE_ACTION).sole
      expect(attached.actor_user).to eq(admin)
      expect(attached.metadata).to include("reversal_audit_id" => reversal.id, "provider_payout_id" => "BANK-LEG-1",
        "verified_return" => include("return_reference" => "RET-LEG-1", "returned_amount_cents" => 1000))
      expect(AuditLog.where(auditable: sent, action: "payout.reconciled").order(:id).last).to eq(reversal)
      expect(platform_only?(payment)).to be(true)
      expect(listing(sent)).to include("return_evidence_required" => false)
      # The reversal stays booked once, in its original month.
      report_after, row_after = cpa_row
      expect(row_after.slice(:organizer_payouts_made_cents, :payout_reversals_cents))
        .to eq(row_before.slice(:organizer_payouts_made_cents, :payout_reversals_cents))
      expect(report_after[:current_integrity_alerts]).to eq(report_before[:current_integrity_alerts])
    end

    it "refuses attaching to a payout that is not reversed, in the application and the database" do
      record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
      paid = payout!("legacy-paid-1")
      reconcile!(paid, "paid", provider_payout_id: "BANK-LEG-P")
      attach!(paid, return_reference: "RET-P", returned_amount_cents: 1000, returned_at: Time.current.utc.iso8601(6))
      expect(response.parsed_body["error"]).to eq("Return evidence is attached only to a payout already recorded reversed")
      expect do
        ActiveRecord::Base.transaction(requires_new: true) do
          raw_return_proof!(paid.reload, kind: "attached_return", returned_at: Time.current, sent_at: paid.paid_at)
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /attached only to a reversal already recorded/)
      expect do
        ActiveRecord::Base.transaction(requires_new: true) do
          raw_return_proof!(paid, returned_at: Time.current, sent_at: paid.paid_at)
          ActiveRecord::Base.connection.execute("SET CONSTRAINTS payout_return_proofs_commit IMMEDIATE")
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /commits only with its payout reversed/)
      expect(PayoutReturnProof.where(payout: paid)).to be_empty
    end
  end

  it "fixes a payout's settlement version once its custody is determined (4704933000)" do
    record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
    paid = payout!("settlement-guard-1")
    other = Settlements::Finalizer.call(event: event, actor: admin)
    pending = create(:payout, organization: organization, event: event, settlement: paid.settlement,
      connected_account: paid.connected_account, status: :pending)
    # No determination yet: the raw reassignment is not the database's to refuse.
    expect(Payout.where(id: pending.id).update_all(settlement_id: other.id)).to eq(1)

    reconcile!(paid, "paid", provider_payout_id: "BANK-SG-1")
    expect(response).to have_http_status(:ok)
    expect(paid.reload.custody_determination.settlement_id).to eq(paid.settlement_id)
    expect do
      ActiveRecord::Base.transaction(requires_new: true) { Payout.where(id: paid.id).update_all(settlement_id: other.id) }
    end.to raise_error(ActiveRecord::StatementInvalid, /settlement version is fixed once its custody is determined/)
    expect(Payout.where(id: paid.id).update_all(settlement_id: paid.settlement_id)).to eq(1)
    expect(paid.reload.settlement_id).not_to eq(other.id)
  end
end
