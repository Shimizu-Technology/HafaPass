# frozen_string_literal: true

require "rails_helper"

# A1-R1 review finding 3 (docs/design/never-fulfilled-captures.md §6.7): the
# payout hold covers the actual entry points of both releases. A pending
# payout reserved before a never-fulfilled item opened cannot be submitted
# after it (the submission authorization is refused), cannot be recorded as
# paid without having been submitted before the hold, and statements cannot
# be finalized. A transfer that really left before the hold is still
# recorded, with its explicit confirmation. Unaffected events are untouched.
# The 7bcd97c2 payout writers run verbatim (spec/support/legacy_7bcd97c2).
RSpec.describe "Never-fulfilled payout evidence holds" do
  include ActiveSupport::Testing::TimeHelpers

  let(:admin) { create(:user, :admin) }
  let(:profile) { create(:organizer_profile, :verified) }
  let(:organization) { profile.organization }
  let(:event) { create(:event, :completed, organization: organization, organizer_profile: profile) }
  let(:other_event) { create(:event, :completed, organization: organization, organizer_profile: profile) }
  let(:gateway_calls) { [] }

  before do
    allow(PayoutGateway).to receive(:submit) do |payout|
      gateway_calls << payout.id
      PayoutGateway::Result.new(provider_payout_id: "manual_po_#{payout.id}", status: :processing)
    end
    allow(Sentry).to receive(:capture_message)
  end

  def sell!(target)
    record_card_sale!(target, ticket_type: create(:ticket_type, event: target, price_cents: 2000), quantity: 5,
      processing_fee_cents: 100)
  end

  # An open never-fulfilled item the refund queue does not cover: a second
  # capture on a legacy order whose fulfilling payment is not proven.
  def open_block!(target)
    order = create(:order, event: target, status: :completed, total_cents: 1360, subtotal_cents: 1360, service_fee_cents: 0)
    create(:payment, :succeeded, order: order, amount_cents: 1360)
    payment = create(:payment, :succeeded, order: order, amount_cents: 1360)
    ReconciliationException.create!(order: order, payment: payment,
      code: Commerce::NeverFulfilledClassification::OWNERSHIP_AMBIGUOUS_CODE, details: { reason: "no_completion_evidence" })
  end

  def reserve!(settlement, key, creator: PayoutCreator)
    creator.new(settlement: settlement, actor: admin, idempotency_key: key).send(:reserve!).first
  end

  def evidence(confirmed_at, **flags)
    { reference: "Bank transfer record", reason: "Transfer confirmed by the bank", confirmed_at: confirmed_at.iso8601(6),
      approved_tax_payee_confirmed: true }.merge(flags)
  end

  before do
    sell!(event)
    approved_bank_account!(organization, actor: profile.user, admin: admin)
  end

  it "refuses this release's pending payout submission after the hold opens, with no gateway call" do
    settlement = Settlements::Finalizer.call(event: event, actor: admin)
    new_payout = reserve!(settlement, "f3-new")
    travel(1.minute) { open_block!(event) }

    expect { PayoutCreator.new(settlement: settlement, actor: admin, idempotency_key: "f3-new").send(:submit_payout!, new_payout) }
      .to raise_error(PayoutCreator::PayoutError, /buyer repayment/)
    expect(gateway_calls).to be_empty
    expect(new_payout.reload).to be_status_pending
  end

  it "refuses 7bcd97c2's pending payout submission and paid recording after the hold opens" do
    settlement = Settlements::Finalizer.call(event: event, actor: admin)
    # Reserved by the old release before the hold existed.
    old_payout = reserve!(settlement, "f3-old", creator: Legacy7bcd97c2.payout_creator)
    travel(1.minute) { open_block!(event) }

    # 7bcd97c2 has no application check: its submission audit is refused.
    expect do
      Legacy7bcd97c2.payout_creator.new(settlement: settlement, actor: admin, idempotency_key: "f3-old")
        .send(:submit_payout!, old_payout)
    end.to raise_error(ActiveRecord::StatementInvalid, /Repayment fence/)
    expect(gateway_calls).to be_empty
    expect(AuditLog.where(action: "payout.submission_requested")).to be_empty
    expect(old_payout.reload).to be_status_pending

    # Never recorded as paid either: nothing was submitted before the hold.
    [PayoutReconciler, Legacy7bcd97c2.payout_reconciler].each do |reconciler|
      expect do
        ActiveRecord::Base.transaction(requires_new: true) do
          reconciler.call(payout: old_payout.reload, actor: admin, status: "paid", provider_payout_id: "bank-f3-unsent",
            evidence: evidence(Time.current, sent_before_hold_confirmed: true))
        end
      end.to raise_error(StandardError, /buyer repayment|Repayment fence/)
    end
    expect(old_payout.reload).to be_status_pending
  end

  it "records the outcome of a 7bcd97c2 submission authorized just before the hold opened" do
    settlement = Settlements::Finalizer.call(event: event, actor: admin)
    # The hold opens while the authorized request is at the gateway.
    allow(PayoutGateway).to receive(:submit) do |submitted|
      travel(1.minute) { open_block!(event) }
      gateway_calls << submitted.id
      PayoutGateway::Result.new(provider_payout_id: "manual_po_#{submitted.id}", status: :processing)
    end

    payout = Legacy7bcd97c2.payout_creator.call(settlement: settlement, actor: admin, idempotency_key: "f3-in-flight")

    expect(gateway_calls).to eq([payout.id])
    expect(Commerce::NeverFulfilledPayoutHold.blocked?(event)).to be(true)
    expect(payout.reload).to have_attributes(status: "processing", provider_payout_id: "manual_po_#{payout.id}")
  end

  it "records a transfer submitted and sent before the hold, only with that confirmation, in both releases" do
    settlement = Settlements::Finalizer.call(event: event, actor: admin)
    payout = PayoutCreator.call(settlement: settlement, actor: admin, idempotency_key: "f3-sent")
    expect(payout).to be_status_processing
    sent_at = 30.seconds.from_now
    travel(2.minutes) { open_block!(event) }

    travel(5.minutes) do
      expect do
        PayoutReconciler.call(payout: payout.reload, actor: admin, status: "paid", provider_payout_id: "bank-f3-1",
          evidence: evidence(sent_at))
      end.to raise_error(PayoutReconciler::ReconciliationError, /sent before the hold/)
      expect do
        PayoutReconciler.call(payout: payout.reload, actor: admin, status: "paid", provider_payout_id: "bank-f3-1",
          evidence: evidence(Time.current, sent_before_hold_confirmed: true))
      end.to raise_error(PayoutReconciler::ReconciliationError, /sent before the hold/)

      PayoutReconciler.call(payout: payout.reload, actor: admin, status: "paid", provider_payout_id: "bank-f3-1",
        evidence: evidence(sent_at, sent_before_hold_confirmed: true))
    end
    expect(payout.reload).to have_attributes(status: "paid", provider_payout_id: "bank-f3-1")
    audit = AuditLog.where(auditable: payout, action: "payout.reconciled").order(:id).last
    expect(audit.metadata).to include("never_fulfilled_hold_started_at")
    expect(audit.metadata["reconciliation"]).to include("sent_before_hold_confirmed" => true)
  end

  it "lets 7bcd97c2 record only money that left before the hold, never on an unrelated event" do
    settlement = Settlements::Finalizer.call(event: event, actor: admin)
    sent = PayoutCreator.call(settlement: settlement, actor: admin, idempotency_key: "f3-old-sent")
    travel(2.minutes) { open_block!(event) }

    travel(5.minutes) do
      Legacy7bcd97c2.payout_reconciler.call(payout: sent.reload, actor: admin, status: "paid", provider_payout_id: "bank-f3-old",
        evidence: evidence(1.minute.ago))
    end
    expect(sent.reload).to be_status_paid

    # The database guards are per event. (OrganizationPayoutBalance's existing
    # rule still holds the organization's other events for any open item.)
    expect(Commerce::NeverFulfilledPayoutHold.blocked?(other_event)).to be(false)
    other_profile = create(:organizer_profile, :verified)
    unrelated = create(:event, :completed, organization: other_profile.organization, organizer_profile: other_profile)
    sell!(unrelated)
    approved_bank_account!(other_profile.organization, actor: other_profile.user, admin: admin)
    other = PayoutCreator.call(settlement: Settlements::Finalizer.call(event: unrelated, actor: admin), actor: admin,
      idempotency_key: "f3-other")
    expect(other).to be_status_processing
    expect(gateway_calls).to include(other.id)
  end

  it "refuses finalization on the held event in both releases" do
    open_block!(event)
    expect { Settlements::Finalizer.call(event: event, actor: admin) }.to raise_error(Settlements::Finalizer::FinalizationError)
    expect do
      Legacy7bcd97c2.settlements_finalizer.call(event: event, actor: admin)
    end.to raise_error(StandardError, /reconciliation exceptions|Repayment fence/)
    expect(Settlement.where(event: event)).to be_empty
  end

  it "closes an evidence hold only through evidence, never by a note in either release" do
    order = create(:order, event: event, status: :completed)
    payment = create(:payment, :succeeded, order: order)
    issue = ReconciliationException.create!(order: order, payment: payment,
      code: Commerce::NeverFulfilledClassification::OWNERSHIP_AMBIGUOUS_CODE)

    expect { ActiveRecord::Base.transaction(requires_new: true) { issue.resolve! } }
      .to raise_error(ActiveRecord::StatementInvalid, /Evidence hold/)
    controller = Api::V1::Admin::ReconciliationExceptionsController.new
    expect(controller.send(:resolution_rule, issue)[:blocked]).to match(/a note cannot close it/)
    second = ReconciliationException.create!(order: order, payment: payment,
      code: Commerce::NeverFulfilledClassification::SECOND_CAPTURE_CODE)
    expect(controller.send(:resolution_rule, second)[:blocked]).to be_present
    expect(Commerce::NeverFulfilledPayoutHold.blocked?(event)).to be(true)
  end
end
