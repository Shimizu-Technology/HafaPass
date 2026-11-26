# frozen_string_literal: true

require "rails_helper"

# A1-R1 recheck of 2f961e48 (docs/design/never-fulfilled-captures.md §6.10):
# an order 7bcd97c2 fulfilled before the upgrade has its sale's payment A
# captured with no recording time and no recorded fulfilling payment. After
# the upgrade, 7bcd97c2 acknowledges B (t1, which opens the hold) and then C
# (t2) before this release discovers either. The payout cutoff stays at t1:
# A counts as the earliest competitor instead of being skipped, C's capture
# only adds a competitor, and neither discovery order (classification,
# ownership ambiguity or quarantine) hides B or moves the cutoff. A payout
# submitted before t1 and transferred between t1 and t2 is refused at every
# step, by this release, by 7bcd97c2's verbatim reconciler and by the
# database; the transfer that left before t1 is still recorded with t1.
# Database clocks are real here (no time travel).
RSpec.describe "Never-fulfilled payout cutoff on an upgraded legacy order" do
  let(:admin) { create(:user, :admin) }
  let(:profile) { create(:organizer_profile, :verified) }
  let(:organization) { profile.organization }
  let(:event) { create(:event, :completed, organization: organization, organizer_profile: profile) }

  before do
    allow(PayoutGateway).to receive(:submit) do |payout|
      PayoutGateway::Result.new(provider_payout_id: "manual_po_#{payout.id}", status: :processing)
    end
    allow(Sentry).to receive(:capture_message)
    approved_bank_account!(organization, actor: profile.user, admin: admin)
  end

  def block_start = Commerce::NeverFulfilledPayoutHold.block_started_at(event)

  # The sale 7bcd97c2 fulfilled before the upgrade: its capture predates the
  # recording-time column and no fulfilling payment is recorded. The
  # completion audit names A when the old release wrote it (it is fail-open).
  def legacy_sale!(audit:, before_upgrade: true)
    sale, _item, a = record_card_sale!(event, ticket_type: create(:ticket_type, event: event, price_cents: 2000), quantity: 5,
      processing_fee_cents: 100)
    stamp!(a, :capture_recorded_at, nil, trigger: "payments_capture_recorded_at") if before_upgrade
    expect(sale.reload.fulfilled_by_payment_id).to be_nil
    if audit
      AuditLogger.record!(action: "order.completed", auditable: sale, organization: organization, event: event,
        outcome: "succeeded", deduplication_key: "order:#{sale.id}:completed", metadata: { payment_id: a.id })
    end
    [sale, a.reload]
  end

  # What 7bcd97c2 writes for a capture on a completed order: the signed
  # receipt (no identity columns), its payment event, the payment captured
  # (the database stamps its recording time) and the receipt processed. No
  # exception. A receipt whose payload was never kept proves nothing.
  def legacy_acknowledge!(sale, intent, proven: true)
    payment = create(:payment, order: sale, amount_cents: sale.total_cents, provider_payment_id: intent, status: :pending)
    payload = if proven
      { "id" => "evt_#{intent}", "type" => "payment_intent.succeeded", "livemode" => false,
        "data" => { "object" => { "id" => intent, "status" => "succeeded", "amount_received" => payment.amount_cents,
          "currency" => "usd" } } }
    else
      {}
    end
    receipt = WebhookEvent.create!(provider: "stripe", provider_event_id: "evt_#{intent}", event_type: "payment_intent.succeeded",
      payload: payload, provider_created_at: 1.second.ago, status: :processing, attempts: 1)
    receipt.create_payment_event!(payment: payment, event_type: "payment_intent.succeeded", amount_cents: payment.amount_cents,
      currency: "usd", provider_created_at: receipt.provider_created_at, data: {})
    payment.update!(status: :succeeded, succeeded_at: Time.current)
    receipt.update!(status: :processed, processed_at: Time.current)
    expect(ReconciliationException.where(payment: payment)).to be_empty
    payment.reload
  end

  def evidence(confirmed_at)
    { reference: "Bank transfer record", reason: "Transfer confirmed by the bank", confirmed_at: confirmed_at.iso8601(6),
      approved_tax_payee_confirmed: true, sent_before_hold_confirmed: true }
  end

  # The same transfer, made between B's and C's captures, in each release and
  # in raw SQL with this release's confirmation named.
  def refuse_gap_transfer!(payout, at)
    expect do
      PayoutReconciler.call(payout: payout.reload, actor: admin, status: "paid", provider_payout_id: "bank-cutoff-new",
        evidence: evidence(at))
    end.to raise_error(PayoutReconciler::ReconciliationError, /sent before the hold/)
    expect do
      ActiveRecord::Base.transaction(requires_new: true) do
        Legacy7bcd97c2.payout_reconciler.call(payout: payout.reload, actor: admin, status: "paid",
          provider_payout_id: "bank-cutoff-old", evidence: evidence(at))
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /fence/)
    expect do
      ActiveRecord::Base.transaction(requires_new: true) do
        FinancialIntegrity.with_settlement_reader do
          FinancialIntegrity.with_payout_transfer(payout.id) do
            Payout.where(id: payout.id).update_all(status: Payout.statuses.fetch("paid"), paid_at: at)
          end
        end
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /verified transfer evidence from before the hold/)
    expect(payout.reload).to be_status_processing
  end

  def holds(payments) = ReconciliationException.where(payment: payments, code: FinancialIntegrity::PAYOUT_BLOCKING_CODES).order(:id)

  def discover!(payment)
    Commerce::NeverFulfilledReconcile.call(dry_run: false, payment_ids: [payment.id]).assessments.sole.disposition
  end

  SCENARIOS = [
    [:recovered, :b_first], [:recovered, :c_first], [:ambiguous, :b_first], [:ambiguous, :c_first]
  ].freeze

  SCENARIOS.each do |ownership, order|
    it "keeps B's capture as the cutoff through C and discovery (#{ownership} ownership, #{order.to_s.tr('_', ' ')}, C unproven)" do
      sale, a = legacy_sale!(audit: ownership == :recovered)
      payout = PayoutCreator.call(settlement: Settlements::Finalizer.call(event: event, actor: admin), actor: admin,
        idempotency_key: "cutoff-#{ownership}-#{order}")
      expect(payout).to be_status_processing
      sleep 0.02
      pre_hold = Time.current
      sleep 0.02
      expect(block_start).to be_nil

      b = legacy_acknowledge!(sale, "pi_cutoff_b")
      t1 = b.capture_recorded_at
      sleep 0.02
      gap = Time.current
      sleep 0.02
      expect(block_start).to be_within(0.001).of(t1)
      refuse_gap_transfer!(payout, gap)

      c = legacy_acknowledge!(sale, "pi_cutoff_c", proven: false)
      t2 = c.capture_recorded_at
      expect(t2).to be > gap
      expect(Commerce::NeverFulfilledReconcile.overlap_capture_ids).to eq([b.id, c.id])
      expect(block_start).to be_within(0.001).of(t1)
      refuse_gap_transfer!(payout, gap)

      first, second = order == :b_first ? [b, c] : [c, b]
      discover!(first)
      # One payment's item never hides the other's liability or its start.
      expect(Commerce::NeverFulfilledReconcile.overlap_capture_ids).to eq([second.id])
      expect(block_start).to be_within(0.001).of(t1)
      refuse_gap_transfer!(payout, gap)
      expect(discover!(second)).to eq(second == c ? "quarantine" : "discover")
      expect(Commerce::NeverFulfilledReconcile.overlap_capture_ids).to be_empty
      expect(block_start).to be_within(0.001).of(t1)
      refuse_gap_transfer!(payout, gap)

      quarantine = ReconciliationException.find_by!(payment: c, code: Commerce::NeverFulfilledClassification::QUARANTINE_CODE)
      expect(quarantine.details).to include("reason" => "receipt_identity_missing")
      if ownership == :recovered
        expect(sale.reload.fulfilled_by_payment_id).to eq(a.id)
        expect(UnfulfilledCapture.find_by!(payment: b)).to have_attributes(capture_scope: "payment", code: "unfulfilled_second_capture")
      else
        expect(sale.reload.fulfilled_by_payment_id).to be_nil
        expect(holds(b).pluck(:code)).to eq([Commerce::NeverFulfilledClassification::OWNERSHIP_AMBIGUOUS_CODE])
      end
      expect(UnfulfilledCapture.where(payment: [a, c])).to be_empty
      expect(holds(a)).to be_empty
      # The first item keeps t1 whichever payment it is on.
      expect(holds([b, c]).first.hold_started_at).to be_within(0.001).of(t1)
      expect(holds(b).map(&:hold_started_at)).to all(be_within(0.001).of(t1))
      expect(holds(c).map(&:hold_started_at)).to all(be <= t2)

      # The transfer that left before B's capture is recorded, with t1.
      PayoutReconciler.call(payout: payout.reload, actor: admin, status: "paid", provider_payout_id: "bank-cutoff-pre",
        evidence: evidence(pre_hold))
      expect(payout.reload).to have_attributes(status: "paid", provider_payout_id: "bank-cutoff-pre")
      audit = AuditLog.where(auditable: payout, action: "payout.reconciled").sole
      expect(Time.iso8601(audit.metadata.fetch("never_fulfilled_hold_started_at"))).to be_within(0.001).of(t1)

      # Once every item on the order is closed, a later item starts at its
      # own time: the episode does not reach back to t1.
      holds([b, c]).open.find_each(&:resolve_with_evidence!)
      expect(block_start).to be_nil
      later = ReconciliationException.create!(order: sale, payment: c,
        code: Commerce::NeverFulfilledResolution::REOPENED_CODE, hold_started_at: 1.year.ago)
      expect(later.reload.hold_started_at).to be_nil
      expect(block_start).to be_within(0.001).of(later.created_at)
    end
  end

  # The cutoff counts the same competitors as discovery: a test-mode capture
  # on a live sale overlaps only once another test capture exists, so the
  # live sale's capture never starts its hold.
  it "uses the predicate's mode rule for the cutoff" do
    sale, a = legacy_sale!(audit: true, before_upgrade: false)
    Payment.where(id: a.id).update_all(provider_environment: "live")
    b = legacy_acknowledge!(sale, "pi_cutoff_mode_b")
    expect(Commerce::NeverFulfilledReconcile.overlap_capture_ids).to be_empty
    expect(block_start).to be_nil
    sleep 0.02
    c = legacy_acknowledge!(sale, "pi_cutoff_mode_c")
    expect(Commerce::NeverFulfilledReconcile.overlap_capture_ids).to eq([b.id, c.id])
    expect(block_start).to be_within(0.001).of(c.capture_recorded_at)
  end
end
