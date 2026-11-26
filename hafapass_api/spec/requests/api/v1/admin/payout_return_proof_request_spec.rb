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
# CodeRabbit review of 758485ae:
#   4705527020 one bank return reference backs one payout's proof;
#   4705527043 no attached return on a placeholder reversal;
#   4705527049 no full account number in attached evidence;
#   4705527061 an identical acceptance retry after the return is idempotent;
#   4705527129 the successful reversal is bound to its own return fixture;
#   4705527141 the check's funded allocations are unchanged by its return.
# A2 recheck at 8132fe22, finding 1: PATCH carries the bank's transfer time
# (transfer_sent_at) for a return that came back before HåfaPass observed
# the provider's paid result.
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
      # CodeRabbit 4706251665: the stub reports no paid time, so the marker
      # is this release's observation, recorded as one.
      expect(conflict.metadata).to include("provider_accepted_basis" => "locally_observed")
      expect(conflict.metadata["observed_paid_at"]).to be_present
      expect(conflict.metadata).not_to have_key("provider_paid_at")
      expect(payout.provider_accepted_basis).to eq("locally_observed")
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
      # CodeRabbit 4707205487: no reversal is offered before the acceptance
      # is recorded (the reconciler refuses it), and then only with the
      # bank's exact return.
      expect(listing(payout)).to include("provider_accepted" => true, "allowed_outcomes" => [])

      # Finance records the acceptance (cash out, once), then the exact return.
      acceptance = { conflict_audit_id: conflict.id, confirmed_at: Time.current.utc.iso8601(6) }
      reconcile!(payout, "accepted_transfer", **acceptance)
      expect(response).to have_http_status(:ok)
      expect(listing(payout)).to include("allowed_outcomes" => ["reversed"],
        "reversal" => include("available" => true, "return_evidence_required" => true, "keeps_transfer_id" => true))
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
        returned_amount_cents: payout.disbursement_cents, sent_at: Time.iso8601(conflict.metadata["observed_paid_at"]))
      _, row = cpa_row
      expect(row).to include(organizer_payouts_made_cents: 1000, payout_reversals_cents: 1000)
      expect(available).to eq(before_payout)

      # CodeRabbit 4705527061: the identical acceptance retried after the
      # return gets the recorded result, with no second booking; different
      # evidence is still refused.
      expect do
        reconcile!(payout, "accepted_transfer", **acceptance)
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to include("id" => payout.id, "status" => "reversed")
      end.not_to(change { AuditLog.where(auditable: payout, action: "payout.accepted_transfer_recorded").count })
      # CodeRabbit 4706251739: the refused retry writes no acceptance audit.
      expect do
        reconcile!(payout, "accepted_transfer", **acceptance, reason: "A different confirmation")
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["error"]).to eq("This payout outcome was already recorded with different evidence")
      end.not_to(change { AuditLog.where(auditable: payout, action: "payout.accepted_transfer_recorded").count })
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
      provider_result!(payout, status: :paid, provider_payout_id: "BANK-LATE-1", paid_at: provider_paid_at,
        provider_reported_paid_at: provider_paid_at)
      expect(payout.reload).to have_attributes(provider_accepted_basis: "provider_reported")
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

    # CodeRabbit 4705527129: the success is X's own return, and its proof is
    # bound to that return's reference (Y's evidence stays in the refusals).
    returned_x = { conflict_audit_id: conflict.id, return_reference: "RET-X-1", returned_amount_cents: payout.disbursement_cents,
      returned_at: Time.current.utc.iso8601(6) }
    reconcile!(payout, "reversed", provider_payout_id: "BANK-X-1", **returned_x)
    expect(response).to have_http_status(:ok)
    expect(payout.reload).to have_attributes(status: "reversed", provider_payout_id: "BANK-X-1")
    expect(payout.return_proof).to have_attributes(kind: "verified_return", sent_at: payout.paid_at,
      return_reference_digest: Digest::SHA256.hexdigest("RET-X-1"))
    expect(payout.return_proof.return_reference_digest).not_to eq(PayoutReturnProof.reference_digest("RET-Y-1"))
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
      # The check's funded line (as a reservation allocates it).
      _order, item, = record_card_sale!(event, ticket_type: ticket_type, quantity: 1)
      PayoutLineAllocation.create!(payout: check, order_item: item, amount_cents: 1000)
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

      # CodeRabbit 4705527141: the funded allocations as they stood before
      # the return, compared after it.
      allocations = -> { PayoutLineAllocation.where(payout: check).order(:id).pluck(:id, :order_item_id, :amount_cents) }
      funded = allocations.call
      expect(funded).not_to be_empty
      reconcile!(check, "reversed", provider_payout_id: "Check 1050", **returned, returned_amount_cents: 900)
      expect(response).to have_http_status(:ok)
      expect(check.reload).to have_attributes(status: "reversed", amount_cents: 1000, disbursement_cents: 1000)
      expect(check.return_proof).to have_attributes(returned_amount_cents: 900, kind: "verified_return")
      expect(return_verified?(check)).to be(true)
      expect(check.payout_check_adjustments.sum(:amount_cents)).to eq(-100)
      expect(allocations.call).to eq(funded)
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
      reconcile!(sent, "paid", provider_payout_id: "BANK-123456789")
      expect(response).to have_http_status(:ok)
      reconcile!(sent, "reversed", provider_payout_id: "BANK-123456789", reason: "Bank returned the transfer")
      expect(response).to have_http_status(:ok)
      expect(sent.reload).to have_attributes(status: "reversed", provider_payout_id: "BANK-123456789")
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
      expect(attached.metadata).to include("reversal_audit_id" => reversal.id, "provider_payout_id" => "BANK-[redacted]",
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

    # CodeRabbit 4705527043 and 4705527049.
    it "never ties a return to a reversal recorded on a placeholder identifier" do
      record_card_sale!(event, ticket_type: ticket_type, quantity: 5, processing_fee_cents: 100)
      # CodeRabbit 4706251749: the placeholder reversal is the event's only
      # payout, on the approved account, so it alone defeats the proof.
      placeholder = create(:payout, organization: organization, event: event, connected_account: organization.connected_accounts.sole,
        amount_cents: 1000, settlement: Settlements::Finalizer.call(event: event, actor: admin), status: :reversed,
        provider_payout_id: "manual_po_legacy_reversal", created_at: 1.hour.ago, initiated_at: 1.hour.ago)
      expect(event.payouts.pluck(:id)).to eq([placeholder.id])
      payment = over_returned_capture!
      expect(event.payouts.pluck(:id)).to eq([placeholder.id])
      expect(platform_only?(payment)).to be(false)
      # The only fact defeating the proof is that reversal (its creation time).
      defeating = -> {
        ActiveRecord::Base.connection.select_values(ActiveRecord::Base.sanitize_sql_array(
          ["SELECT started FROM hafapass_overpaid_proof_facts(?) WHERE defeating", payment.id]))
          .map { |started| Time.zone.parse(started.to_s).to_i }
      }
      expect(defeating.call).to eq([placeholder.reload.created_at.to_i])
      expect(listing(placeholder)).to include("return_evidence_required" => true)

      exact = { return_reference: "RET-PH-1", returned_amount_cents: 1000, returned_at: Time.current.utc.iso8601(6) }
      [nil, "manual_po_legacy_reversal", "BANK-SOMETHING-ELSE"].each do |claimed|
        attach!(placeholder, provider_payout_id: claimed, **exact)
        expect([claimed, response.parsed_body["error"]]).to eq([claimed, PayoutReconciler::PLACEHOLDER_REVERSAL_MESSAGE])
      end
      expect(PayoutReturnProof.where(payout: placeholder)).to be_empty
      expect(AuditLog.where(auditable: placeholder, action: PayoutReconciler::RETURN_EVIDENCE_ACTION)).to be_empty
      expect(return_verified?(placeholder)).to be(false)
      # Unknown funds stay with the organizer: the event stays held.
      expect(platform_only?(payment)).to be(false)
      expect(defeating.call).to eq([placeholder.created_at.to_i])
      expect(placeholder.reload).to have_attributes(status: "reversed", provider_payout_id: "manual_po_legacy_reversal")
    end

    it "refuses a full bank account number in attached evidence before any audit or proof" do
      sent, payment = reversed_then_classified!
      number = sent.connected_account.bank_account_number
      expect(number).to be_present
      exact = { return_reference: "RET-ACCT-1", returned_amount_cents: 1000, returned_at: Time.current.utc.iso8601(6) }
      [{ reason: "Returned to account #{number} by the bank" }, { reference: "Statement #{number}" },
        { return_reference: "RET #{number}" }].each do |field|
        attach!(sent, **exact, **field)
        expect([field.keys, response.parsed_body["error"]]).to eq([field.keys, "Leave full bank account numbers out of payout evidence"])
      end
      expect(PayoutReturnProof.where(payout: sent)).to be_empty
      expect(AuditLog.where(auditable: sent, action: PayoutReconciler::RETURN_EVIDENCE_ACTION)).to be_empty
      expect(platform_only?(payment)).to be(false)
      attach!(sent, **exact)
      expect(response).to have_http_status(:ok)
      expect(platform_only?(payment)).to be(true)
    end
  end

  describe "a bank return reference backs one payout's return (4705527020)" do
    it "refuses another payout's reference in every path and the database, and replays the same payout's retry" do
      record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
      first = payout!("ref-a")
      reconcile!(first, "paid", provider_payout_id: "BANK-REF-A")
      second = payout!("ref-b")
      reconcile!(second, "paid", provider_payout_id: "BANK-REF-B")
      legacy = payout!("ref-c")
      reconcile!(legacy, "paid", provider_payout_id: "BANK-REF-C")
      reconcile!(legacy, "reversed", provider_payout_id: "BANK-REF-C", reason: "Bank returned the transfer")
      expect(legacy.reload).to be_status_reversed
      expect(legacy.return_proof).to be_nil

      exact = { return_reference: "RET-SHARED-1", returned_amount_cents: 1000, returned_at: Time.current.utc.iso8601(6),
        confirmed_at: Time.current.utc.iso8601(6) }
      reconcile!(first, "reversed", provider_payout_id: "BANK-REF-A", **exact)
      expect(response).to have_http_status(:ok)
      digest = first.reload.return_proof.return_reference_digest
      after_first = available

      # The same payout's identical retry returns the recorded result.
      reconcile!(first, "reversed", provider_payout_id: "BANK-REF-A", **exact)
      expect(response).to have_http_status(:ok)
      expect(PayoutReturnProof.where(return_reference_digest: digest).pluck(:payout_id)).to eq([first.id])

      # Another payout cannot use that return, in any case or spacing
      # (CodeRabbit 4706251644: internal and non-ASCII spacing and
      # full-width forms too).
      ["RET-SHARED-1", " ret-shared-1 ", "Ret-Shared-1", "RET-SHARED -1", "R E T-SHARED-1", "RET\u00A0-SHARED-1",
        "ＲＥＴ－ＳＨＡＲＥＤ－１"].each do |reference|
        reconcile!(second, "reversed", provider_payout_id: "BANK-REF-B", **exact, return_reference: reference)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["error"]).to eq(PayoutReconciler::RETURN_REFERENCE_USED_MESSAGE)
        attach!(legacy, provider_payout_id: "BANK-REF-C", **exact, return_reference: reference)
        expect(response.parsed_body["error"]).to eq(PayoutReconciler::RETURN_REFERENCE_USED_MESSAGE)
      end
      expect(second.reload).to have_attributes(status: "paid", provider_payout_id: "BANK-REF-B")
      expect(PayoutReturnProof.where(payout: [second, legacy])).to be_empty
      expect(AuditLog.where(auditable: [second, legacy], action: PayoutReconciler::RETURN_EVIDENCE_ACTION)).to be_empty
      expect(AuditLog.where(auditable: second, action: "payout.reconciled").where("after_data->>'status' = 'reversed'")).to be_empty
      expect(available).to eq(after_first)
      # The database refuses it for any writer (the digest is unique across
      # every payout and organization; no scope column).
      expect do
        ActiveRecord::Base.transaction(requires_new: true) do
          raw_return_proof!(legacy, kind: "attached_return", reference: "ret-shared-1", returned_at: Time.current,
            sent_at: legacy.paid_at)
        end
      end.to raise_error(ActiveRecord::RecordNotUnique, /index_payout_return_proofs_on_return_reference_digest/)

      # Each payout's own return still records.
      reconcile!(second, "reversed", provider_payout_id: "BANK-REF-B", **exact, return_reference: "RET-SHARED-2")
      expect(response).to have_http_status(:ok)
      attach!(legacy, provider_payout_id: "BANK-REF-C", **exact, return_reference: "RET-SHARED-3")
      expect(response).to have_http_status(:ok)
      expect(PayoutReturnProof.where(payout: [first, second, legacy]).pluck(:return_reference_digest).uniq.size).to eq(3)
    end
  end

  # A2 recheck finding 1 (8132fe22): the reviewer's case through the admin
  # API. A held $10.00 transfer the provider accepted (observed only), which
  # finance acknowledged, came back before HåfaPass observed the paid
  # result. The PATCH used to drop transfer_sent_at: 422, still held, no
  # proof.
  describe "a bank return before HåfaPass observed the paid result (transfer_sent_at)" do
    def accepted_held!
      record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
      allow(PayoutGateway).to receive(:submit) do |_payout|
        EventCancellationRefunds.hold_payouts!(event, actor: admin)
        sleep 0.05 # the observation comes measurably after the submission request
        PayoutGateway::Result.new(provider_payout_id: "BANK-OBS-API", status: :paid)
      end
      settlement = Settlements::Finalizer.call(event: event, actor: admin)
      @before_payout = available
      payout = payout!("observed-api", settlement: settlement)
      expect(payout.reload).to have_attributes(status: "held", held_from_status: "processing",
        provider_accepted_basis: "locally_observed", provider_payout_id: "BANK-OBS-API")
      payout
    end

    it "records the exact return with the bank's transfer time, and refuses one outside its bounds" do
      payout = accepted_held!
      conflict = AuditLog.where(auditable: payout, action: "payout.provider_result_conflict")
        .where("metadata->>'conflict_reason' = ?", PayoutCreator::PAID_REFUSED_REASON).sole
      reconcile!(payout, "accepted_transfer", conflict_audit_id: conflict.id)
      expect(response).to have_http_status(:ok)
      observed = payout.reload.provider_accepted_at
      submitted_at = AuditLog.where(auditable: payout, action: "payout.submission_requested").sole.occurred_at
      bank_sent = (submitted_at + ((observed - submitted_at) / 3)).utc.floor(6)
      returned_at = (bank_sent + ((observed - bank_sent) / 2)).utc.floor(6)
      expect([submitted_at < bank_sent, bank_sent < returned_at, returned_at < observed]).to eq([true, true, true])
      committed = available
      returned = { conflict_audit_id: conflict.id, return_reference: "RET-OBS-API-1", returned_amount_cents: 1000,
        returned_at: returned_at.iso8601(6) }
      unchanged = lambda do
        expect(payout.reload).to have_attributes(status: "held", held_from_status: "processing")
        expect(payout.return_proof).to be_nil
        expect(available).to eq(committed)
      end

      # Without the bank's time the return predates the observation.
      reconcile!(payout, "reversed", **returned)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to match(/after the provider accepted the transfer/)
      unchanged.call
      # A bank time before the submission request or after the observation.
      [submitted_at - 1.second, observed + 1.second].each do |outside|
        reconcile!(payout, "reversed", **returned, transfer_sent_at: outside.utc.iso8601(6))
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["error"]).to eq(PayoutReconciler::TRANSFER_SENT_AT_RANGE_MESSAGE)
        unchanged.call
      end
      expect(AuditLog.where(auditable: payout, action: "payout.reconciled").where("after_data->>'status' = 'reversed'")).to be_empty

      # Within its bounds the exact return reverses it, dated by the bank.
      reconcile!(payout, "reversed", **returned, transfer_sent_at: bank_sent.iso8601(6))
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("status" => "reversed", "provider_payout_id" => "BANK-OBS-API")
      # The deferred reversal check accepts it at commit.
      expect { ActiveRecord::Base.connection.execute("SET CONSTRAINTS payouts_reversal_return_check IMMEDIATE") }
        .not_to raise_error
      expect(payout.reload).to be_status_reversed
      expect(payout.return_proof).to have_attributes(kind: "accepted_transfer_return", returned_amount_cents: 1000,
        sent_at: bank_sent, returned_at: returned_at,
        return_reference_digest: PayoutReturnProof.reference_digest("RET-OBS-API-1"))
      reversal = AuditLog.where(auditable: payout, action: "payout.reconciled").order(:id).last
      expect(reversal.metadata["accepted_transfer_return"]).to include("accepted_at" => observed.utc.iso8601(6),
        "accepted_basis" => "locally_observed", "transfer_sent_at" => bank_sent.iso8601(6), "sent_at" => bank_sent.iso8601(6))
      expect(available).to eq(@before_payout)
      expect(committed).to be <= @before_payout - 1000
    end
  end

  # CodeRabbit 4706251688: the list reads the durable marker first, and
  # offers no outcome for an acceptance shown only by its audit.
  it "offers no outcome for an acceptance shown only by its audit" do
    record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
    payout = payout!("listing-evidence-only")
    Payout.where(id: payout.id).update_all(provider_payout_id: "BANK-LIST-EO", failure_code: "provider_result_conflict")
    AuditLogger.record!(action: "payout.provider_result_conflict", auditable: payout.reload, actor: admin,
      organization: organization, event: event, source: "provider", outcome: "unknown",
      metadata: { conflict_reason: PayoutCreator::PAID_REFUSED_REASON })
    expect(listing(payout)).to include("provider_accepted" => true, "provider_acceptance_evidence_only" => true,
      "provider_accepted_basis" => nil, "allowed_outcomes" => [])
    reconcile!(payout, "accepted_transfer", conflict_audit_id: AuditLog.where(auditable: payout).order(:id).last.id)
    expect(response.parsed_body["error"]).to eq(PayoutReconciler::EVIDENCE_ONLY_ACCEPTANCE_MESSAGE)
  end

  it "lists an acceptance from its durable marker after its audits are redacted" do
    record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
    allow(PayoutGateway).to receive(:submit) do |_payout|
      EventCancellationRefunds.hold_payouts!(event, actor: admin)
      PayoutGateway::Result.new(provider_payout_id: "BANK-LIST-MK", status: :paid)
    end
    held = payout!("listing-marker-held")
    expect(held.reload.provider_accepted_at).to be_present
    AuditLog.redact!(AuditLog.where(auditable: held), { ip_address: nil, before_data: {}, after_data: {}, metadata: {},
      retention_anonymized_at: Time.current, updated_at: Time.current })
    # CodeRabbit 4707205487: "reversed" is offered once finance records the
    # accepted transfer (the reconciler refuses it before then).
    expect(listing(held)).to include("provider_accepted" => true, "provider_acceptance_evidence_only" => false,
      "provider_accepted_basis" => "locally_observed", "allowed_outcomes" => [],
      "reversal" => include("available" => false, "unavailable_reason" => PayoutReconciler::ACCEPTED_RETURN_BEFORE_ACCEPTANCE_MESSAGE))
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
