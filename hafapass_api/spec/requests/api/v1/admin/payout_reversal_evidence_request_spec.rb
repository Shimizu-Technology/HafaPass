# frozen_string_literal: true

require "rails_helper"

# CodeRabbit review of bca5f904 (PR #249), the admin outcome flow:
#   4707205487 the listing says what a reversal needs (payout.reversal), so
#              the outcome form asks for the bank's exact return on an event
#              with a never-fulfilled capture, and never offers a reversal
#              that is always refused;
#   4707205465 an accepted transfer (marker or paid-refusal audit) never
#              shows a send instruction;
#   4707205504 identical retries are recognized by the evidence fingerprint,
#              not the sanitized (truncated) audit text, and a changed
#              suffix is refused;
#   4707205517 a parsed timestamp is not an account number.
RSpec.describe "Admin payout reversal evidence", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  let(:admin) { create(:user, :admin) }
  let(:profile) { create(:organizer_profile, :verified) }
  let(:organization) { profile.organization }
  let(:event) { create(:event, :completed, organization: organization, organizer_profile: profile) }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 2000) }

  around(:each, :fixed_payout_timeline) do |example|
    travel_to(6.minutes.ago.change(usec: 0))
    example.run
  ensure
    travel_back
  end

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

  # The body the admin outcome dialog sends (AdminPayoutsPage ReconcileDialog).
  def reconcile!(payout, status, provider_payout_id: nil, **evidence)
    patch "/api/v1/admin/payouts/#{payout.id}", headers: auth_headers(admin), as: :json,
      params: { status: status, provider_payout_id: provider_payout_id,
        evidence: { reference: "Bank statement line 14", reason: "Bank confirms the outcome",
          confirmed_at: Time.current.utc.iso8601(6), approved_tax_payee_confirmed: true, **evidence } }.compact
  end

  def payout!(key, amount_cents: 1000)
    PayoutCreator.call(settlement: Settlements::Finalizer.call(event: event, actor: admin), actor: admin,
      idempotency_key: key, amount_cents: amount_cents)
  end

  def listing(payout)
    get "/api/v1/admin/payouts", headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    response.parsed_body["payouts"].find { |row| row["id"] == payout.id }
  end

  def classify_event!
    order, payment, = classified_capture(items: [[1200, 160, 0, 0]], event: event)
    component = create(:fee_component, order: order, order_item: order.order_items.first, kind: "processing",
      amount_cents: 69, estimated: false, provider_reference: "txn_rev_#{SecureRandom.hex(4)}")
    create(:stripe_fee_evidence, :verified, payment: payment, fee_component: component,
      provider_balance_transaction_id: component.provider_reference)
    expect(PayoutReconciler.classified_event?(Payout.new(event: event))).to be(true)
  end

  def available
    OrganizationPayoutBalance.available_cents(organization)
  end

  describe "a paid manual payout on an event with a never-fulfilled capture" do
    it "lists the exact return the form must supply and records it from the form's request" do
      record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
      payout = payout!("rev-paid")
      reconcile!(payout, "paid", provider_payout_id: "BANK-REV-PAID-1")
      expect(response).to have_http_status(:ok)
      paid_at = payout.reload.paid_at
      classify_event!
      committed = available

      row = listing(payout)
      expect(row["allowed_outcomes"]).to eq(["reversed"])
      expect(row["reversal"]).to eq("available" => true, "return_evidence_required" => true, "amount_cents" => 1000,
        "earliest_returned_at" => paid_at.utc.iso8601(6), "keeps_transfer_id" => true, "transfer_id" => "BANK-REV-PAID-1",
        "transfer_sent_at_allowed" => false, "transfer_sent_at_from" => nil)
      expect(row["dispatch"]).to be_nil

      # The generic reversal (what the dialog sent before) stays refused.
      reconcile!(payout, "reversed", reason: "Bank returned it")
      expect(response.parsed_body["error"]).to eq(PayoutReconciler::CLASSIFIED_RETURN_REQUIRED_MESSAGE)
      # The form's own checks mirror these refusals.
      exact = { return_reference: "RET-FORM-1", returned_amount_cents: 1000, returned_at: Time.current.utc.iso8601(6) }
      reconcile!(payout, "reversed", **exact, returned_amount_cents: 999)
      expect(response.parsed_body["error"]).to eq("The returned amount must be the full 1000 cents that left")
      reconcile!(payout, "reversed", **exact, returned_at: (paid_at - 1.minute).utc.iso8601(6))
      expect(response.parsed_body["error"]).to eq("The return time must be after the transfer left and not in the future")
      expect(payout.reload).to have_attributes(status: "paid", provider_payout_id: "BANK-REV-PAID-1")
      expect(payout.return_proof).to be_nil
      expect(available).to eq(committed)

      # The dialog keeps the stored transfer ID (it sends none for a paid
      # payout) and sends the three return fields.
      reconcile!(payout, "reversed", **exact)
      expect(response).to have_http_status(:ok)
      expect { ActiveRecord::Base.connection.execute("SET CONSTRAINTS payouts_reversal_return_check IMMEDIATE") }
        .not_to raise_error
      expect(payout.reload).to have_attributes(status: "reversed", provider_payout_id: "BANK-REV-PAID-1")
      expect(payout.return_proof).to have_attributes(kind: "verified_return", returned_amount_cents: 1000,
        return_reference_digest: PayoutReturnProof.reference_digest("RET-FORM-1"))
      expect(available).to eq(committed + 1000)
      expect(listing(payout)).to include("allowed_outcomes" => [], "reversal" => nil)
    end

    it "asks for the real transfer identifier when the payout holds only the request placeholder" do
      record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
      payout = payout!("rev-placeholder")
      expect(payout.reload).to have_attributes(status: "processing", provider_payout_id: "manual_po_#{payout.id}")
      classify_event!
      row = listing(payout)
      expect(row["reversal"]).to include("available" => true, "return_evidence_required" => true,
        "keeps_transfer_id" => false, "transfer_id" => nil)
      expect(row["allowed_outcomes"]).to include("reversed")
      exact = { return_reference: "RET-PLACE-1", returned_amount_cents: 1000, returned_at: Time.current.utc.iso8601(6) }
      reconcile!(payout, "reversed", **exact)
      expect(response.parsed_body["error"]).to eq(PayoutReconciler::RETURN_IDENTITY_MESSAGE)
      reconcile!(payout, "reversed", provider_payout_id: "BANK-REV-REAL-1", **exact)
      expect(response).to have_http_status(:ok)
      expect(payout.reload).to have_attributes(status: "reversed", provider_payout_id: "BANK-REV-REAL-1")
      expect(payout.return_proof.kind).to eq("verified_return")
    end

    it "never offers a reversal with nothing that left to return" do
      record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
      payout = payout!("rev-nothing-left")
      reconcile!(payout, "paid", provider_payout_id: "BANK-REV-ZERO-1")
      classify_event!
      payout.reload
      allow(payout).to receive(:confirmed_check_amount_cents).and_return(0)
      expect(PayoutReconciler.reversal_evidence(payout, classified: true, accepted: false, evidence_only: false))
        .to eq(available: false, return_evidence_required: true,
          unavailable_reason: PayoutReconciler::NOTHING_LEFT_TO_RETURN_MESSAGE)
    end
  end

  it "keeps the generic reversal on an event without a never-fulfilled capture" do
    record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
    payout = payout!("rev-ordinary")
    reconcile!(payout, "paid", provider_payout_id: "BANK-REV-ORD-1")
    row = listing(payout)
    expect(row["allowed_outcomes"]).to eq(["reversed"])
    expect(row["reversal"]).to eq("available" => true, "return_evidence_required" => false)
    reconcile!(payout, "reversed", reason: "Bank returned it")
    expect(response).to have_http_status(:ok)
    expect(payout.reload).to be_status_reversed
    expect(payout.return_proof).to be_nil
  end

  describe "an accepted transfer is never shown a send instruction (4707205465)" do
    it "makes a placeholder with a paid-refusal conflict audit not actionable, naming the acceptance first" do
      record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
      payout = payout!("dispatch-audit-only")
      control = listing(payout)
      expect(control["dispatch"]).to include("actionable" => true, "placeholder" => true, "reasons" => [])
      Payout.where(id: payout.id).update_all(failure_code: "provider_result_conflict")
      AuditLogger.record!(action: "payout.provider_result_conflict", auditable: payout.reload, actor: admin,
        organization: organization, event: event, source: "provider", outcome: "unknown",
        metadata: { conflict_reason: PayoutCreator::PAID_REFUSED_REASON })
      row = listing(payout)
      expect(row).to include("provider_accepted" => true, "provider_acceptance_evidence_only" => true,
        "allowed_outcomes" => [], "reversal" => nil)
      expect(row["dispatch"]).to include("actionable" => false, "placeholder" => true, "reasons" => ["accepted"])
      expect(row["dispatch"]["messages"].first).to eq(PayoutEntryGuard::DISPATCH_REASONS.fetch("accepted"))
    end

    it "offers the return of a marked acceptance only after finance records it, with the bank's optional transfer time" do
      record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
      allow(PayoutGateway).to receive(:submit) do |_payout|
        EventCancellationRefunds.hold_payouts!(event, actor: admin)
        PayoutGateway::Result.new(provider_payout_id: "BANK-REV-ACC-1", status: :paid)
      end
      payout = payout!("rev-accepted")
      expect(payout.reload).to have_attributes(status: "held", provider_accepted_basis: "locally_observed")
      row = listing(payout)
      expect(row["allowed_outcomes"]).to eq([])
      expect(row["reversal"]).to eq("available" => false, "return_evidence_required" => true,
        "unavailable_reason" => PayoutReconciler::ACCEPTED_RETURN_BEFORE_ACCEPTANCE_MESSAGE)
      conflict = AuditLog.where(auditable: payout, action: "payout.provider_result_conflict").order(:id).last
      reconcile!(payout, "accepted_transfer", provider_payout_id: "BANK-REV-ACC-1", conflict_audit_id: conflict.id)
      expect(response).to have_http_status(:ok)
      submitted = AuditLog.where(auditable: payout, action: "payout.submission_requested").minimum(:occurred_at)
      row = listing(payout)
      expect(row["allowed_outcomes"]).to eq(["reversed"])
      expect(row["reversal"]).to eq("available" => true, "return_evidence_required" => true, "amount_cents" => 1000,
        "earliest_returned_at" => payout.reload.provider_accepted_at.utc.iso8601(6), "keeps_transfer_id" => true,
        "transfer_id" => "BANK-REV-ACC-1", "transfer_sent_at_allowed" => true,
        "transfer_sent_at_from" => submitted.utc.iso8601(6))
    end
  end

  describe "identical retries and the evidence fingerprint (4707205504)" do
    let(:long_reason) { "Finance confirmed the bank transfer record line by line. " * 11 }

    it "returns the recorded outcome for an identical long reason and refuses a changed suffix" do
      expect(long_reason.length).to be_between(600, 1000)
      record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
      payout = payout!("fp-paid")
      confirmed_at = Time.current.utc.iso8601(6)
      reconcile!(payout, "paid", provider_payout_id: "BANK-FP-1", reason: long_reason, confirmed_at: confirmed_at)
      expect(response).to have_http_status(:ok)
      audit = AuditLog.where(auditable: payout, action: "payout.reconciled").sole
      # The sanitized copy is truncated; the fingerprint is letters only.
      expect(audit.metadata.dig("reconciliation", "reason").length).to be <= AuditSanitizer::MAX_TEXT_LENGTH
      expect(audit.metadata["evidence_fingerprint"]).to match(/\A[a-p]{64}\z/)
      expect(audit.metadata.to_json).not_to include(long_reason)

      reconcile!(payout, "paid", provider_payout_id: "BANK-FP-1", reason: long_reason, confirmed_at: confirmed_at)
      expect(response).to have_http_status(:ok)
      changed = "#{long_reason[0, 550]}but the second half of this explanation was edited later."
      reconcile!(payout, "paid", provider_payout_id: "BANK-FP-1", reason: changed, confirmed_at: confirmed_at)
      expect(response.parsed_body["error"]).to eq("This payout outcome was already recorded with different evidence")
      expect(AuditLog.where(auditable: payout, action: "payout.reconciled").count).to eq(1)
    end

    it "does not treat a truncated A1 audit reason as an identical request" do
      recorded = AuditSanitizer.call({ "reason" => long_reason })
      audit = AuditLog.new(metadata: { "reconciliation" => recorded })

      expect(recorded.fetch("reason").length).to eq(AuditSanitizer::MAX_TEXT_LENGTH)
      expect(PayoutReconciler.send(:same_evidence?, audit, recorded)).to be(false)
      expect(PayoutReconciler.send(:same_evidence?, audit, { "reason" => long_reason })).to be(false)

      intact = { "reason" => "Verified bank transfer" }
      audit.metadata = { "reconciliation" => intact }
      expect(PayoutReconciler.send(:same_evidence?, audit, intact)).to be(true)
    end

    it "does not replay the sanitized URL from a legacy audit" do
      ["https://bank.example/transfer?ref=abc", "https://operator:pass@bank.example/transfer",
        "https://bank.example/transfer#line-four"].each do |reference|
        original = { "reference" => reference }
        recorded = AuditSanitizer.call(original)
        audit = AuditLog.new(metadata: { "reconciliation" => recorded })

        expect(recorded).to eq("reference" => "https://bank.example/transfer")
        expect(PayoutReconciler.send(:same_evidence?, audit, recorded)).to be(false)
        expect(PayoutReconciler.send(:same_evidence?, audit, original)).to be(false)
      end
    end

    it "does the same for the accepted-transfer acknowledgement" do
      record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
      allow(PayoutGateway).to receive(:submit) do |_payout|
        EventCancellationRefunds.hold_payouts!(event, actor: admin)
        PayoutGateway::Result.new(provider_payout_id: "BANK-FP-ACC-1", status: :paid)
      end
      payout = payout!("fp-accepted")
      conflict = AuditLog.where(auditable: payout, action: "payout.provider_result_conflict").order(:id).last
      confirmed_at = Time.current.utc.iso8601(6)
      acknowledge = lambda do |reason|
        reconcile!(payout, "accepted_transfer", provider_payout_id: "BANK-FP-ACC-1", conflict_audit_id: conflict.id,
          reason: reason, confirmed_at: confirmed_at)
      end
      acknowledge.call(long_reason)
      expect(response).to have_http_status(:ok)
      recorded_at = payout.reload.accepted_transfer_recorded_at
      acknowledge.call(long_reason)
      expect(response).to have_http_status(:ok)
      acknowledge.call("#{long_reason[0, 520]}with a different ending")
      expect(response.parsed_body["error"]).to eq("This payout outcome was already recorded with different evidence")
      expect(AuditLog.where(auditable: payout, action: "payout.accepted_transfer_recorded").count).to eq(1)
      expect(payout.reload.accepted_transfer_recorded_at).to eq(recorded_at)
    end
  end

  # 4707205517: the bank's transfer time is excluded by key, like the
  # confirmation and return times; the same digits in free text are not.
  it "accepts a valid bank transfer time whose digits match the account number, and still refuses them in text",
    :fixed_payout_timeline do
    record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
    submitted = Time.current + 1.minute
    bank_sent = submitted + 1.minute
    returned_at = submitted + 2.minutes
    observed = submitted + 3.minutes
    allow(PayoutGateway).to receive(:submit) do |_payout|
      EventCancellationRefunds.hold_payouts!(event, actor: admin)
      travel_to(observed)
      PayoutGateway::Result.new(provider_payout_id: "BANK-TS-1", status: :paid)
    end
    travel_to(submitted)
    payout = payout!("ts-account")
    travel_to(observed + 1.minute)
    conflict = AuditLog.where(auditable: payout, action: "payout.provider_result_conflict").order(:id).last
    reconcile!(payout, "accepted_transfer", provider_payout_id: "BANK-TS-1", conflict_audit_id: conflict.id)
    expect(response).to have_http_status(:ok)
    expect(payout.reload.provider_accepted_at).to eq(observed)
    expect(AuditLog.where(auditable: payout, action: "payout.submission_requested").sole.occurred_at).to eq(submitted)
    digits = bank_sent.utc.iso8601(6).gsub(/\D/, "")[0, 10]
    allow_any_instance_of(ConnectedAccount).to receive(:bank_account_number).and_return(digits)
    returned = { conflict_audit_id: conflict.id, return_reference: "RET-TS-1", returned_amount_cents: 1000,
      returned_at: returned_at.iso8601(6) }

    reconcile!(payout, "reversed", provider_payout_id: "BANK-TS-1", **returned, transfer_sent_at: bank_sent.iso8601(6),
      reason: "Bank returned it; account #{digits}")
    expect(response.parsed_body["error"]).to eq("Leave full bank account numbers out of payout evidence")
    expect(payout.reload).to be_status_held
    reconcile!(payout, "reversed", provider_payout_id: "BANK-TS-1", **returned, transfer_sent_at: bank_sent.iso8601(6))
    expect(response).to have_http_status(:ok)
    expect(payout.reload).to be_status_reversed
    expect(payout.return_proof.sent_at).to eq(bank_sent)
  end
end
