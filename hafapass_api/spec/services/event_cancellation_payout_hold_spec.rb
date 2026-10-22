require "rails_helper"

RSpec.describe "Cancelled event payout holds" do
  let(:profile) { create(:organizer_profile, :verified) }
  let(:event) { create(:event, :published, organizer_profile: profile) }
  let(:admin) { create(:user, :admin) }
  let!(:tax) do
    event.organization.organizer_tax_information || create(:organizer_tax_information, organization: event.organization)
  end
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
    expect(payout.held_from_status).to eq("pending")
    expect(payout.settlement.paid_or_processing_cents).to eq(reserved_before)
    expect(AuditLog.where(auditable: payout, action: "payout.held_for_cancellation")).to exist
  end

  it "also holds a processing payout when a legacy refund run starts" do
    payout
    event.update!(status: :cancelled)
    EventCancellationRefunds.prepare!(event: event, actor: admin)
    expect(payout.reload).to be_status_held
    expect(payout.held_from_status).to eq("processing")
  end

  it "releases and audits the original status after the refund run completes with no buyer liability" do
    payout.update!(status: :pending)
    EventLifecycle.call(event: event, action: :cancel, actor: profile.user, reason: "Storm")
    create(:balance_adjustment, event: event, organization: event.organization, amount_cents: 1000)
    run = event.reload.event_cancellation_refund_run
    create(:refund, order: order, payment: payment, amount_cents: payment.amount_cents)
    run.items.update_all(status: EventCancellationRefundItem.statuses.fetch("refunded"))

    run.reconcile_status!

    expect(run.reload).to be_completed
    expect(payout.reload).to be_status_pending
    expect(payout.held_from_status).to be_nil
    audit = AuditLog.find_by!(auditable: payout, action: "payout.released_from_cancellation_hold")
    expect(audit.before_data["status"]).to eq("held")
    expect(audit.after_data["status"]).to eq("pending")
    expect(audit.metadata["automatic"]).to be(true)
  end

  it "keeps automatic release held when withholding becomes required" do
    payout.update!(status: :pending)
    EventLifecycle.call(event: event, action: :cancel, actor: profile.user, reason: "Storm")
    create(:balance_adjustment, event: event, organization: event.organization, amount_cents: 1000)
    run = event.reload.event_cancellation_refund_run
    create(:refund, order: order, payment: payment, amount_cents: payment.amount_cents)
    run.items.update_all(status: EventCancellationRefundItem.statuses.fetch("refunded"))
    tax.update!(backup_withholding_flag: true, backup_withholding_reason: "IRS notice received")
    run.reconcile_status!
    expect(payout.reload).to be_status_held
    expect(AuditLog.where(auditable: payout, action: "payout.released_from_cancellation_hold")).not_to exist
  end

  it "keeps a held payout when a pending refund still makes the buyer liability unresolved" do
    payout
    EventLifecycle.call(event: event, action: :cancel, actor: profile.user, reason: "Storm")
    create(:balance_adjustment, event: event, organization: event.organization, amount_cents: 1000)
    create(:refund, order: order, payment: payment, amount_cents: payment.amount_cents,
      status: :pending, succeeded_at: nil)
    run = event.reload.event_cancellation_refund_run
    run.items.update_all(status: EventCancellationRefundItem.statuses.fetch("skipped"))

    run.reconcile_status!

    expect(payout.reload).to be_status_held
    expect(AuditLog.where(auditable: payout, action: "payout.released_from_cancellation_hold")).not_to exist
  end

  it "blocks release when refunds reduced net payable below the held payout" do
    payout
    EventLifecycle.call(event: event, action: :cancel, actor: profile.user, reason: "Storm")
    create(:refund, order: order, payment: payment, amount_cents: payment.amount_cents)

    expect do
      PayoutHoldRelease.call(payout: payout, actor: admin)
    end.to raise_error(PayoutHoldRelease::ReleaseError, /cancel and reissue/)
    expect(payout.reload).to be_status_held
  end

  it "requires explicit prior-send confirmation for a manual release while buyers remain owed" do
    payout
    EventLifecycle.call(event: event, action: :cancel, actor: profile.user, reason: "Storm")
    create(:balance_adjustment, event: event, organization: event.organization, amount_cents: 1000)
    expect do
      PayoutHoldRelease.call(payout: payout, actor: admin)
    end.to raise_error(PayoutHoldRelease::ReleaseError, /Buyer refunds remain unresolved/)

    PayoutHoldRelease.call(payout: payout, actor: admin, sent_before_cancellation_confirmed: true,
      cancellation_payout_reason: "Transfer sent before cancellation notice")
    expect(payout.reload).to be_status_processing
    expect(AuditLog.find_by!(auditable: payout, action: "payout.released_from_cancellation_hold")
      .metadata["cancellation_payout_reason"]).to eq("Transfer sent before cancellation notice")
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

  it "keeps transfer evidence and a conflict marker when a held payout receives a processing result" do
    payout
    EventLifecycle.call(event: event, action: :cancel, actor: profile.user, reason: "Storm")
    creator = PayoutCreator.new(settlement: payout.settlement, actor: profile.user, idempotency_key: payout.idempotency_key)
    creator.send(:record_submission_outcome!, payout, status: :processing,
      provider_payout_id: "bank-processing-42", initiated_at: Time.current)

    expect(payout.reload).to have_attributes(status: "held", provider_payout_id: "bank-processing-42",
      failure_code: "provider_result_conflict")
    expect(AuditLog.where(auditable: payout, action: "payout.provider_result_conflict")).to exist
    expect { PayoutHoldRelease.call(payout: payout, actor: admin) }
      .to raise_error(PayoutHoldRelease::ReleaseError, /provider result conflict/)
  end

  it "preserves an unknown submission result when cancellation places the hold" do
    payout.update!(failure_code: "provider_result_unknown", failure_message: "Timed out")
    EventLifecycle.call(event: event, action: :cancel, actor: profile.user, reason: "Storm")

    expect(payout.reload.failure_code).to eq("provider_result_unknown")
    expect(payout.failure_message).to include("provider result remains unknown")
  end

  it "does not submit to the gateway after a payout was held" do
    payout.update!(status: :pending)
    EventLifecycle.call(event: event, action: :cancel, actor: profile.user, reason: "Storm")
    creator = PayoutCreator.new(settlement: payout.settlement, actor: profile.user, idempotency_key: payout.idempotency_key)
    allow(PayoutGateway).to receive(:submit)

    expect { creator.send(:submit_payout!, payout) }.to raise_error(PayoutCreator::PayoutError, /held before submission/)
    expect(PayoutGateway).not_to have_received(:submit)
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
