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
  # The captures are recorded at the (travelled) application time: the
  # exception is written while the second capture is still unclassified, so
  # the database keeps that capture's hold start on it (§6.9), and the
  # database's own clock does not travel.
  def open_block!(target)
    order = create(:order, event: target, status: :completed, total_cents: 1360, subtotal_cents: 1360, service_fee_cents: 0)
    create(:payment, :succeeded, order: order, amount_cents: 1360, capture_recorded_at: Time.current)
    payment = create(:payment, :succeeded, order: order, amount_cents: 1360, capture_recorded_at: Time.current)
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

  # A1-R1 recheck blocker 2: a submission authorized before the hold proves
  # a request was sent, not that money left. The database records paid on a
  # held event only with a transfer time before the hold and this release's
  # verified confirmation; 7bcd97c2 never gives one, so it is refused even
  # for a genuine pre-hold transfer (this release records that one).
  it "refuses 7bcd97c2's paid recording after a pre-hold submission, whatever transfer time it is given" do
    settlement = Settlements::Finalizer.call(event: event, actor: admin)
    sent = PayoutCreator.call(settlement: settlement, actor: admin, idempotency_key: "f3-old-sent")
    expect(sent).to be_status_processing
    sent_at = 30.seconds.from_now
    issue = travel(2.minutes) { open_block!(event) }
    hold_started_at = Commerce::NeverFulfilledPayoutHold.block_started_at(event)
    expect(hold_started_at).to be_within(0.001).of(issue.created_at)

    travel(5.minutes) do
      # A transfer time after the hold: refused, as before.
      expect do
        ActiveRecord::Base.transaction(requires_new: true) do
          Legacy7bcd97c2.payout_reconciler.call(payout: sent.reload, actor: admin, status: "paid", provider_payout_id: "bank-f3-old",
            evidence: evidence(1.minute.ago))
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /verified transfer evidence from before the hold/)
      # A transfer time before the hold, from the old release: still refused
      # (its confirmation is not verified; this release records it below).
      expect do
        ActiveRecord::Base.transaction(requires_new: true) do
          Legacy7bcd97c2.payout_reconciler.call(payout: sent.reload, actor: admin, status: "paid", provider_payout_id: "bank-f3-old",
            evidence: evidence(sent_at, sent_before_hold_confirmed: true))
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /verified transfer evidence from before the hold/)
      # Editing a timestamp alone never passes.
      expect do
        ActiveRecord::Base.transaction(requires_new: true) { Payout.where(id: sent.id).update_all(status: :paid, paid_at: sent_at) }
      end.to raise_error(ActiveRecord::StatementInvalid, /verified transfer evidence/)
      # The confirmation named without a pre-hold transfer time: the cutoff
      # is the database's, not only the application's.
      expect do
        ActiveRecord::Base.transaction(requires_new: true) do
          FinancialIntegrity.with_payout_transfer(sent.id) { Payout.where(id: sent.id).update_all(status: :paid, paid_at: Time.current) }
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /verified transfer evidence/)
    end
    expect(sent.reload).to be_status_processing
    expect(sent.paid_at).to be_nil

    # This release records the genuine pre-hold transfer with its evidence.
    travel(6.minutes) do
      PayoutReconciler.call(payout: sent.reload, actor: admin, status: "paid", provider_payout_id: "bank-f3-new",
        evidence: evidence(sent_at, sent_before_hold_confirmed: true))
    end
    expect(sent.reload).to have_attributes(status: "paid", provider_payout_id: "bank-f3-new")
    expect(sent.paid_at).to be_within(0.001).of(sent_at)
    submission = AuditLog.find_by!(auditable: sent, action: "payout.submission_requested")
    reconciled = AuditLog.where(auditable: sent, action: "payout.reconciled").sole
    expect(submission.occurred_at).to be < hold_started_at
    expect(Time.iso8601(reconciled.metadata.fetch("never_fulfilled_hold_started_at"))).to be_within(0.001).of(hold_started_at)
    expect(reconciled.metadata["reconciliation"]).to include("sent_before_hold_confirmed" => true)

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
    Legacy7bcd97c2.payout_reconciler.call(payout: other.reload, actor: admin, status: "paid", provider_payout_id: "bank-f3-other",
      evidence: evidence(Time.current))
    expect(other.reload).to be_status_paid
  end

  # A1-R1 boundary fix 2 (§6.9): the hold an overlap capture opens starts at
  # that capture and keeps that start when discovery classifies or
  # quarantines it. A payout submitted before the capture and transferred in
  # the gap between capture and discovery is refused before discovery and,
  # with the same transfer time and confirmation, after it, by this release
  # and by the database; a transfer that left before the capture is still
  # recorded. Database clocks are real here (no time travel): the capture
  # time is stamped by the database.
  %i[quarantine classify].each do |discovery|
    it "keeps the capture's hold start through discovery (#{discovery}) for the same during-gap transfer" do
      sale, _item, a = sell!(event)
      sale.update!(fulfilled_by_payment_id: a.id)
      settlement = Settlements::Finalizer.call(event: event, actor: admin)
      payout = PayoutCreator.call(settlement: settlement, actor: admin, idempotency_key: "f2-gap-#{discovery}")
      expect(payout).to be_status_processing
      sleep 0.02
      pre_hold = Time.current
      sleep 0.02
      b = create(:payment, order: sale, amount_cents: sale.total_cents, status: :pending)
      if discovery == :classify
        payload = { "id" => "evt_f2_#{b.id}", "type" => "payment_intent.succeeded", "livemode" => false,
          "data" => { "object" => { "id" => b.provider_payment_id, "status" => "succeeded", "amount_received" => b.amount_cents,
            "currency" => "usd" } } }
        receipt = WebhookEvent.create!(provider: "stripe", provider_event_id: payload["id"], event_type: "payment_intent.succeeded",
          payload: payload, provider_created_at: 1.second.ago, status: :processed, attempts: 1, processed_at: Time.current)
        receipt.create_payment_event!(payment: b, event_type: "payment_intent.succeeded", amount_cents: b.amount_cents,
          currency: "usd", provider_created_at: receipt.provider_created_at, data: {})
      end
      # 7bcd97c2 acknowledges B on the fulfilled sale: no exception.
      b.update!(status: :succeeded, succeeded_at: Time.current)
      captured_at = b.reload.capture_recorded_at
      sleep 0.02
      during_gap = Time.current
      sleep 0.02
      expect(Commerce::NeverFulfilledPayoutHold.block_started_at(event)).to be_within(0.001).of(captured_at)

      attempts = lambda do
        expect do
          PayoutReconciler.call(payout: payout.reload, actor: admin, status: "paid", provider_payout_id: "bank-f2-#{discovery}",
            evidence: evidence(during_gap, sent_before_hold_confirmed: true))
        end.to raise_error(PayoutReconciler::ReconciliationError, /sent before the hold/)
        expect do
          ActiveRecord::Base.transaction(requires_new: true) do
            # This release's reader and confirmation named in raw SQL: the hold
            # still refuses it.
            FinancialIntegrity.with_settlement_reader do
              FinancialIntegrity.with_payout_transfer(payout.id) do
                Payout.where(id: payout.id).update_all(status: Payout.statuses.fetch("paid"), paid_at: during_gap)
              end
            end
          end
        end.to raise_error(ActiveRecord::StatementInvalid, /verified transfer evidence from before the hold/)
        expect do
          ActiveRecord::Base.transaction(requires_new: true) do
            Legacy7bcd97c2.payout_reconciler.call(payout: payout.reload, actor: admin, status: "paid",
              provider_payout_id: "bank-f2-old-#{discovery}", evidence: evidence(during_gap, sent_before_hold_confirmed: true))
          end
        end.to raise_error(ActiveRecord::StatementInvalid, /fence/)
        expect(payout.reload).to be_status_processing
      end
      attempts.call

      Commerce::NeverFulfilledReconcile.discover_overlap_captures!

      if discovery == :classify
        expect(UnfulfilledCapture.find_by!(payment: b).capture_scope).to eq("payment")
      else
        expect(ReconciliationException.find_by!(payment: b, code: Commerce::NeverFulfilledClassification::QUARANTINE_CODE)
          .details).to include("reason" => "capture_receipt_missing")
      end
      issues = ReconciliationException.where(payment: b)
      expect(issues).to be_present
      expect(issues.map(&:created_at)).to all(be > during_gap)
      expect(Commerce::NeverFulfilledPayoutHold.block_started_at(event)).to be_within(0.001).of(captured_at)
      attempts.call
      expect(issues.map(&:hold_started_at)).to all(be_within(0.001).of(captured_at))

      # The transfer that left before B's capture is still recorded.
      PayoutReconciler.call(payout: payout.reload, actor: admin, status: "paid", provider_payout_id: "bank-f2-#{discovery}",
        evidence: evidence(pre_hold, sent_before_hold_confirmed: true))
      expect(payout.reload).to have_attributes(status: "paid", provider_payout_id: "bank-f2-#{discovery}")
      audit = AuditLog.where(auditable: payout, action: "payout.reconciled").sole
      expect(Time.iso8601(audit.metadata.fetch("never_fulfilled_hold_started_at"))).to be_within(0.001).of(captured_at)
    end
  end

  # The in-flight outcome stays recordable (processing), and a held payout
  # is never released on a held event by either release.
  it "keeps a pre-hold in-flight payout processing and refuses releasing a held payout in both releases" do
    settlement = Settlements::Finalizer.call(event: event, actor: admin)
    in_flight = PayoutCreator.call(settlement: settlement, actor: admin, idempotency_key: "f3-held")
    sent_at = 20.seconds.from_now
    travel(1.minute) { in_flight.update!(status: :held, held_from_status: "processing") }
    travel(2.minutes) { open_block!(event) }

    travel(5.minutes) do
      expect { PayoutHoldRelease.call(payout: in_flight.reload, actor: admin) }
        .to raise_error(PayoutHoldRelease::ReleaseError, /buyer repayment/)
      # 7bcd97c2's PayoutHoldRelease is this one without the application check.
      allow(Commerce::NeverFulfilledPayoutHold).to receive(:blocked?).and_return(false)
      expect do
        ActiveRecord::Base.transaction(requires_new: true) { PayoutHoldRelease.call(payout: in_flight.reload, actor: admin) }
      end.to raise_error(ActiveRecord::StatementInvalid, /Repayment fence/)
      expect(in_flight.reload).to have_attributes(status: "held", held_from_status: "processing")
      expect do
        ActiveRecord::Base.transaction(requires_new: true) do
          Legacy7bcd97c2.payout_reconciler.call(payout: in_flight.reload, actor: admin, status: "paid", provider_payout_id: "bank-f3-held-old",
            evidence: evidence(sent_at, sent_before_hold_confirmed: true))
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /Repayment fence/)
      allow(Commerce::NeverFulfilledPayoutHold).to receive(:blocked?).and_call_original

      PayoutReconciler.call(payout: in_flight.reload, actor: admin, status: "paid", provider_payout_id: "bank-f3-held",
        evidence: evidence(sent_at, sent_before_hold_confirmed: true))
    end
    expect(in_flight.reload).to have_attributes(status: "paid", provider_payout_id: "bank-f3-held")
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
