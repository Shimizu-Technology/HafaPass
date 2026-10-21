require "rails_helper"

RSpec.describe "Cancelled event payout holds" do
  let(:profile) { create(:organizer_profile, :verified) }
  let(:event) { create(:event, :published, organizer_profile: profile) }
  let(:admin) { create(:user, :admin) }
  let(:order) { create(:order, event: event) }
  let!(:payment) { create(:payment, :succeeded, order: order, provider_environment: "live") }
  let(:payout) do
    create(:payout, event: event, organization: event.organization, status: :processing,
      provider_payout_id: "manual_po_fixture", created_at: 1.hour.ago, with_tax_snapshot: false)
  end
  let(:evidence) do
    { reference: "Bank statement 42", reason: "Matched the transfer", confirmed_at: Time.current.iso8601,
      legacy_payee_name: "Actual payee", legacy_evidence_note: "Bank statement 42", legacy_payee_confirmed: true }
  end

  it "holds and audits a pending payout when the event is cancelled" do
    payout.update!(status: :pending)
    reserved_before = payout.settlement.paid_or_processing_cents
    EventLifecycle.call(event: event, action: :cancel, actor: profile.user, reason: "Storm")
    expect(payout.reload).to be_status_held
    expect(payout.settlement.paid_or_processing_cents).to eq(reserved_before)
    expect(AuditLog.where(auditable: payout, action: "payout.held_for_cancellation")).to exist
  end

  it "also holds a processing payout when a legacy refund run starts" do
    payout
    event.update!(status: :cancelled)
    EventCancellationRefunds.prepare!(event: event, actor: admin)
    expect(payout.reload).to be_status_held
  end

  it "keeps a late submission result held and escalates reported payment for reconciliation" do
    payout
    EventLifecycle.call(event: event, action: :cancel, actor: profile.user, reason: "Storm")
    creator = PayoutCreator.new(settlement: payout.settlement, actor: profile.user, idempotency_key: payout.idempotency_key)
    creator.send(:record_submission_outcome!, payout, status: :paid,
      provider_payout_id: "bank-late-42", initiated_at: Time.current, paid_at: Time.current)
    expect(payout.reload).to be_status_held
    expect(payout.failure_code).to eq("provider_result_conflict")
    expect(AuditLog.where(auditable: payout, action: "payout.provider_result_conflict")).to exist
  end

  it "blocks recording a held payout as paid without prior-send confirmation" do
    payout
    EventLifecycle.call(event: event, action: :cancel, actor: profile.user, reason: "Storm")
    expect do
      PayoutReconciler.call(payout: payout, actor: admin, status: "paid", provider_payout_id: "bank-transfer-42",
        evidence: evidence)
    end.to raise_error(PayoutReconciler::ReconciliationError, /already sent before the cancellation/)
    expect(payout.reload).to be_status_held
  end

  it "also requires confirmation while a provider refund is pending against the full balance" do
    payout
    EventLifecycle.call(event: event, action: :cancel, actor: profile.user, reason: "Storm")
    create(:refund, order: order, payment: payment, amount_cents: 5250, status: :pending, succeeded_at: nil)
    expect(EventCancellationRefunds.outstanding_balance_cents(event)).to eq(0)
    expect(EventCancellationRefunds.unresolved?(event)).to be(true)
    expect do
      PayoutReconciler.call(payout: payout, actor: admin, status: "paid", provider_payout_id: "bank-transfer-42",
        evidence: evidence)
    end.to raise_error(PayoutReconciler::ReconciliationError, /already sent before the cancellation/)
  end

  it "records an already sent payout with explicit evidence and preserves the buyer liability" do
    payout
    EventLifecycle.call(event: event, action: :cancel, actor: profile.user, reason: "Storm")
    PayoutReconciler.call(payout: payout, actor: admin, status: "paid", provider_payout_id: "bank-transfer-42",
      evidence: evidence.merge(sent_before_cancellation_confirmed: true,
        cancellation_payout_reason: "Check cleared before the cancellation notice"))
    expect(payout.reload).to be_status_paid
    audit = AuditLog.find_by!(auditable: payout, action: "payout.reconciled")
    expect(audit.metadata.dig("reconciliation", "sent_before_cancellation_confirmed")).to be(true)
    expect(audit.metadata["outstanding_buyer_balance_cents"]).to eq(5250)
    expect(EventCancellationRefunds.outstanding_balance_cents(event)).to eq(5250)
  end

  it "does not require cancellation confirmation for a normal event" do
    payout
    PayoutReconciler.call(payout: payout, actor: admin, status: "paid", provider_payout_id: "bank-transfer-42",
      evidence: evidence)
    expect(payout.reload).to be_status_paid
  end
end
