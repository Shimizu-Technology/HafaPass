# frozen_string_literal: true

require "rails_helper"

# CodeRabbit review of a292e277, provider acceptance boundaries:
#   4706251677 a paid result refused by the payout fence on a pending payout
#              whose hold cutoff predates its submission: the move to
#              processing is refused by the same cutoff, yet the acceptance
#              (reference, marker, conflict) must commit and stay committed
#              for every writer;
#   4706251665 the marker is the provider's reported paid time, or only this
#              release's observation of the paid result (an upper bound),
#              recorded as such; a return is compared with the bank's
#              earlier transfer time when finance shows it;
#   4706251703 finance's acknowledgement is recorded by an earlier write than
#              the reversal, and only by the audited reconciler path;
#   4706251688 an acceptance shown only by its audit (no marker) gets no
#              outcome: it stays committed for an approved disposition.
RSpec.describe "Provider acceptance boundaries (A2)" do
  let(:admin) { create(:user, :admin) }
  let(:profile) { create(:organizer_profile, :verified) }
  let(:organization) { profile.organization }
  let(:event) { create(:event, :completed, organization: organization, organizer_profile: profile) }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 2000) }
  let(:fence) { /(?:Accepted transfer|Payout reversal|Repayment|Payout entry) fence[^\n]*/ }

  before do
    allow(StripeService).to receive(:verify_payment_context!)
    allow(StripeProcessingFees).to receive(:require_adjustment_review!)
    allow(EmailService).to receive(:send_refund_notification_async)
    allow(Sentry).to receive(:capture_message)
    allow(Sentry).to receive(:capture_exception)
    approved_bank_account!(organization, actor: profile.user, admin: admin)
    stub_gateway!
  end

  def evidence(**extra)
    { reference: "Bank transfer record", reason: "Bank confirms the outcome", confirmed_at: Time.current.utc.iso8601(6),
      approved_tax_payee_confirmed: true, **extra }
  end

  def available
    OrganizationPayoutBalance.available_cents(organization)
  end

  def stub_gateway!(&block)
    @calls = 0
    allow(PayoutGateway).to receive(:submit) do |payout|
      @calls += 1
      block ? block.call(payout) : PayoutGateway::Result.new(provider_payout_id: "manual_po_#{payout.id}", status: :processing)
    end
  end

  def commit_check!
    ActiveRecord::Base.connection.execute("SET CONSTRAINTS payouts_reversal_return_check IMMEDIATE")
  end

  # A write as another release (A1 during the overlap or after a rollback)
  # or raw SQL makes it, rolled back. Returns :accepted or the fence message.
  def raw(payout, **columns)
    ActiveRecord::Base.transaction(requires_new: true) do
      yield if block_given?
      Payout.where(id: payout.id).update_all(columns) if columns.any?
      commit_check!
      raise ActiveRecord::Rollback
    end
    :accepted
  rescue ActiveRecord::StatementInvalid => e
    e.message[fence] || raise
  end

  def raw_return_proof!(payout, sent_at:, returned_at: Time.current, kind: "accepted_transfer_return")
    FinancialIntegrity.with_payout_return(payout.id) do
      PayoutReturnProof.create!(payout: payout, kind: kind, returned_amount_cents: payout.confirmed_check_amount_cents,
        returned_at: returned_at, sent_at: sent_at, return_reference_digest: PayoutReturnProof.reference_digest("RET-RAW-#{payout.id}"))
    end
  end

  def conflict(payout)
    AuditLog.where(auditable: payout, action: "payout.provider_result_conflict").order(:id).last
  end

  def acknowledge!(payout)
    PayoutReconciler.call(payout: payout.reload, actor: admin, status: "accepted_transfer",
      provider_payout_id: payout.provider_payout_id, evidence: evidence(conflict_audit_id: conflict(payout)&.id).compact)
  end

  def reverse!(payout, returned_at:, reference:, **extra)
    PayoutReconciler.call(payout: payout.reload, actor: admin, status: "reversed", provider_payout_id: payout.provider_payout_id,
      evidence: evidence(conflict_audit_id: conflict(payout)&.id, return_reference: reference,
        returned_amount_cents: payout.disbursement_cents, returned_at: returned_at.utc.iso8601(6), **extra).compact)
  end

  # A hold whose cutoff predates the payout's submission: it opens while the
  # gateway call runs, dated an hour earlier (an exception's hold starts at
  # its own creation, as a backdated overlap capture's would), and the
  # provider then reports the $10.00 transfer paid on the still-pending row.
  def accepted_after_stale_cutoff!(key: "stale", paid_at: nil)
    order, = record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
    settlement = Settlements::Finalizer.call(event: event, actor: admin)
    @available_before_payout = available
    stub_gateway! do |payout|
      expect(payout.reload).to be_status_pending
      create(:reconciliation_exception, order: order, code: "unfulfilled_second_capture", created_at: 1.hour.ago)
      PayoutGateway::Result.new(provider_payout_id: "BANK-STALE-#{key}", status: :paid, paid_at: paid_at)
    end
    payout = PayoutCreator.call(settlement: settlement, actor: admin, idempotency_key: "acc-#{key}", amount_cents: 1000)
    stub_gateway!
    payout.reload
  end

  describe "a paid result refused twice on a pending payout (4706251677)" do
    it "reproduces both refusals at the cutoff, then commits the acceptance and keeps it committed for every writer" do
      payout = accepted_after_stale_cutoff!
      submitted_at = AuditLog.where(auditable: payout, action: "payout.submission_requested").sole.occurred_at
      expect(Commerce::NeverFulfilledPayoutHold.block_started_at(event)).to be < submitted_at

      # The acceptance committed with its refusal: in flight, the provider's
      # reference, the durable marker (observed: no provider time), the
      # conflict audit naming the paid refusal.
      expect(payout).to have_attributes(status: "processing", failure_code: "provider_result_conflict",
        provider_payout_id: "BANK-STALE-stale", provider_accepted_basis: "locally_observed", paid_at: nil)
      expect(payout.provider_accepted_at).to be_within(5.seconds).of(Time.current)
      expect(conflict(payout).metadata).to include("conflict_reason" => PayoutCreator::PAID_REFUSED_REASON,
        "provider_accepted_basis" => "locally_observed")
      expect(conflict(payout).metadata["refusal"]).to match(/Repayment fence: payout #{payout.id} needs verified transfer evidence/)

      # Without the marker nothing leaves pending (the fence's own cutoff
      # rule is unchanged for every other write; the red run on a292e277
      # shows it refusing the marked move too).
      expect(raw(payout, status: Payout.statuses[:pending], provider_accepted_at: nil)).to match(/are fixed|never recorded paid/)

      # No resend: the same key returns this payout without a gateway call;
      # a fresh key cannot reserve while the event is held and the amount is
      # committed.
      expect(PayoutCreator.call(settlement: payout.settlement, actor: admin, idempotency_key: "acc-stale", amount_cents: 1000))
        .to eq(payout)
      expect(@calls).to eq(0)
      expect do
        PayoutCreator.call(settlement: payout.settlement, actor: admin, idempotency_key: "acc-stale-fresh", amount_cents: 1000)
      end.to raise_error(PayoutCreator::PayoutError)
      expect(@calls).to eq(0)
      expect(available).to be <= @available_before_payout - 1000

      # A1's generic outcomes and raw SQL: never pending, failed, paid,
      # released or reversed without the acknowledgement and exact return.
      transfer = payout.provider_payout_id
      expect(raw(payout, status: Payout.statuses[:pending])).to match(/never recorded paid, failed, pending/)
      expect(raw(payout, status: Payout.statuses[:failed], failure_code: "reconciled_failure")).to match(/never recorded paid/)
      expect(raw(payout, status: Payout.statuses[:paid], paid_at: Time.current, failure_code: nil)).to match(/never recorded paid/)
      expect(raw(payout, status: Payout.statuses[:reversed], failure_code: nil)).to match(/record the accepted transfer before its return/)
      expect(raw(payout, provider_payout_id: "OTHER")).to match(/are fixed/)
      expect(raw(payout, provider_accepted_basis: "provider_reported")).to match(/are fixed/)
      expect do
        PayoutReconciler.call(payout: payout.reload, actor: admin, status: "failed", provider_payout_id: transfer,
          evidence: evidence(conflict_audit_id: conflict(payout).id))
      end.to raise_error(PayoutReconciler::ReconciliationError, PayoutReconciler::ACCEPTED_NOT_FAILED_MESSAGE)
      expect(payout.reload).to have_attributes(status: "processing", provider_payout_id: transfer)

      # Finance acknowledges it, then the bank's exact return frees it once.
      acknowledge!(payout)
      expect(payout.reload.accepted_transfer_recorded_at).to be_present
      reverse!(payout, returned_at: Time.current, reference: "RET-STALE-1")
      expect { commit_check! }.not_to raise_error
      expect(payout.reload).to have_attributes(status: "reversed", provider_payout_id: transfer)
      expect(payout.return_proof).to have_attributes(kind: "accepted_transfer_return", sent_at: payout.provider_accepted_at)
    end
  end

  describe "provider-reported and locally observed acceptance times (4706251665)" do
    it "keeps a provider's reported paid time as the marker and compares the return with it" do
      reported = 3.minutes.ago.utc.floor(6)
      payout = accepted_after_stale_cutoff!(key: "reported", paid_at: reported)
      expect(payout).to have_attributes(provider_accepted_basis: "provider_reported", provider_accepted_at: reported)
      expect(conflict(payout).metadata).to include("provider_paid_at" => reported.iso8601(6),
        "provider_accepted_basis" => "provider_reported")
      expect(conflict(payout).metadata).not_to have_key("observed_paid_at")
      acknowledge!(payout)
      expect { reverse!(payout, returned_at: reported - 1.second, reference: "RET-REP-1") }
        .to raise_error(PayoutReconciler::ReconciliationError, /after the provider accepted the transfer/)
      # The bank's time never replaces a provider-reported one.
      expect do
        reverse!(payout, returned_at: reported + 1.second, reference: "RET-REP-1", transfer_sent_at: (reported - 1.minute).iso8601(6))
      end.to raise_error(PayoutReconciler::ReconciliationError, PayoutReconciler::TRANSFER_SENT_AT_MESSAGE)
      reverse!(payout, returned_at: reported + 1.second, reference: "RET-REP-1")
      expect(payout.reload.return_proof).to have_attributes(sent_at: reported, returned_at: reported + 1.second)
    end

    it "records an observed paid time as an observation and proves an earlier bank transfer time from finance's evidence" do
      payout = accepted_after_stale_cutoff!(key: "observed")
      observed = payout.provider_accepted_at
      submitted_at = AuditLog.where(auditable: payout, action: "payout.submission_requested").sole.occurred_at
      expect(payout.provider_accepted_basis).to eq("locally_observed")
      expect(conflict(payout).metadata).to include("observed_paid_at" => observed.utc.iso8601(6))
      expect(conflict(payout).metadata).not_to have_key("provider_paid_at")
      acknowledge!(payout)
      acceptance = AuditLog.where(auditable: payout, action: "payout.accepted_transfer_recorded").sole
      expect(acceptance.metadata).to include("provider_accepted_basis" => "locally_observed",
        "provider_accepted_at" => observed.utc.iso8601(6))

      bank_sent = submitted_at + ((observed - submitted_at) / 2)
      returned = bank_sent + ((observed - bank_sent) / 2)
      # The observation is not the provider's time: a return between the
      # bank's transfer and the observation needs the bank's transfer time.
      expect { reverse!(payout, returned_at: returned, reference: "RET-OBS-1") }
        .to raise_error(PayoutReconciler::ReconciliationError, /after the provider accepted the transfer/)
      [submitted_at - 1.second, observed + 1.second].each do |outside|
        expect { reverse!(payout, returned_at: returned, reference: "RET-OBS-1", transfer_sent_at: outside.utc.iso8601(6)) }
          .to raise_error(PayoutReconciler::ReconciliationError, PayoutReconciler::TRANSFER_SENT_AT_RANGE_MESSAGE)
      end
      expect { reverse!(payout, returned_at: bank_sent - 0.001, reference: "RET-OBS-1", transfer_sent_at: bank_sent.utc.iso8601(6)) }
        .to raise_error(PayoutReconciler::ReconciliationError, /after the provider accepted the transfer/)
      # The database refuses a proof sent before the submission request.
      early = raw(payout, status: Payout.statuses[:reversed], failure_code: nil) do
        raw_return_proof!(payout, sent_at: submitted_at - 1.second, returned_at: returned)
      end
      expect(early).to match(/record its return from the current release/)
      expect(payout.reload).to be_status_processing

      reverse!(payout, returned_at: returned, reference: "RET-OBS-1", transfer_sent_at: bank_sent.utc.iso8601(6))
      expect { commit_check! }.not_to raise_error
      expect(payout.reload).to be_status_reversed
      expect(payout.return_proof.sent_at).to be_within(0.000_001.seconds).of(bank_sent)
      reversal = AuditLog.where(auditable: payout, action: "payout.reconciled").order(:id).last
      expect(reversal.metadata["accepted_transfer_return"]).to include("accepted_at" => observed.utc.iso8601(6),
        "accepted_basis" => "locally_observed", "transfer_sent_at" => bank_sent.utc.iso8601(6),
        "sent_at" => bank_sent.utc.iso8601(6))
    end

    it "takes the bank's transfer time only on the return of an accepted transfer" do
      record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
      payout = PayoutCreator.call(settlement: Settlements::Finalizer.call(event: event, actor: admin), actor: admin,
        idempotency_key: "ordinary-sent", amount_cents: 1000)
      expect do
        PayoutReconciler.call(payout: payout, actor: admin, status: "paid", provider_payout_id: "BANK-ORD-SENT",
          evidence: evidence(transfer_sent_at: Time.current.utc.iso8601(6)))
      end.to raise_error(PayoutReconciler::ReconciliationError, PayoutReconciler::TRANSFER_SENT_AT_MESSAGE)
      expect(payout.reload).to be_status_processing
    end
  end

  describe "acknowledgement before reversal (4706251703)" do
    it "refuses one update that stamps the acknowledgement and reverses, and a stamp from any other writer" do
      payout = accepted_after_stale_cutoff!(key: "same-update")
      exact = -> { raw_return_proof!(payout, sent_at: payout.provider_accepted_at) }
      # The reviewer's write: stamp and reversal together, with the exact
      # return proof in the same transaction.
      expect(raw(payout, status: Payout.statuses[:reversed], failure_code: nil, accepted_transfer_recorded_at: Time.current, &exact))
        .to match(/only from the current release's reconciler/)
      # Even a writer that names the payout as the reconciler does: the stamp
      # must already be on the row (OLD) when it is reversed.
      named = raw(payout) do
        FinancialIntegrity.with_payout_acceptance(payout.id) do
          exact.call
          Payout.where(id: payout.id).update_all(status: Payout.statuses[:reversed], failure_code: nil,
            accepted_transfer_recorded_at: Time.current)
        end
      end
      expect(named).to match(/record the accepted transfer before its return/)
      # Stamped separately but outside the audited reconciler path.
      expect(raw(payout, accepted_transfer_recorded_at: Time.current)).to match(/only from the current release's reconciler/)
      stamped_then_reversed = raw(payout) do
        Payout.where(id: payout.id).update_all(accepted_transfer_recorded_at: Time.current)
        Payout.where(id: payout.id).update_all(status: Payout.statuses[:reversed], failure_code: nil)
        exact.call
      end
      expect(stamped_then_reversed).to match(/only from the current release's reconciler/)
      expect(payout.reload).to have_attributes(status: "processing", accepted_transfer_recorded_at: nil)
      expect(AuditLog.where(auditable: payout, action: "payout.accepted_transfer_recorded")).to be_empty

      # The audited acknowledgement, then the exact return in a later write.
      acknowledge!(payout)
      recorded_at = payout.reload.accepted_transfer_recorded_at
      expect(AuditLog.where(auditable: payout, action: "payout.accepted_transfer_recorded").count).to eq(1)
      expect(raw(payout, status: Payout.statuses[:reversed], failure_code: nil, &exact)).to eq(:accepted)
      reverse!(payout, returned_at: Time.current, reference: "RET-SAME-1")
      expect { commit_check! }.not_to raise_error
      expect(payout.reload).to have_attributes(status: "reversed", accepted_transfer_recorded_at: recorded_at)
    end
  end

  describe "an acceptance shown only by its audit (4706251688)" do
    # Unreachable from any release (the marker and its audit are written in
    # one transaction); built here the only way it can exist, by a direct
    # write: an in-flight conflict with the paid-refusal audit, no marker.
    def evidence_only!
      record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
      payout = PayoutCreator.call(settlement: Settlements::Finalizer.call(event: event, actor: admin), actor: admin,
        idempotency_key: "evidence-only", amount_cents: 1000)
      Payout.where(id: payout.id).update_all(provider_payout_id: "BANK-EVIDENCE-ONLY", failure_code: "provider_result_conflict",
        failure_message: "Provider reported payment after a fence")
      AuditLogger.record!(action: "payout.provider_result_conflict", auditable: payout.reload, actor: admin,
        organization: organization, event: event, source: "provider", outcome: "unknown",
        metadata: { conflict_reason: PayoutCreator::PAID_REFUSED_REASON, provider_paid_at: 10.minutes.ago.utc.iso8601(6) })
      payout.reload
    end

    it "keeps it committed and records no outcome, in the application and the database" do
      payout = evidence_only!
      expect(PayoutCreator.provider_accepted?(payout)).to be(true)
      expect(PayoutCreator.evidence_only_acceptance?(payout)).to be(true)
      reserved = available
      [["accepted_transfer", {}], ["reversed", { return_reference: "RET-EO-1", returned_amount_cents: 1000,
        returned_at: Time.current.utc.iso8601(6) }], ["failed", {}], ["paid", {}]].each do |status, extra|
        expect do
          PayoutReconciler.call(payout: payout.reload, actor: admin, status: status, provider_payout_id: "BANK-EVIDENCE-ONLY",
            evidence: evidence(conflict_audit_id: conflict(payout).id, **extra))
        end.to raise_error(PayoutReconciler::ReconciliationError, PayoutReconciler::EVIDENCE_ONLY_ACCEPTANCE_MESSAGE)
      end
      expect(payout.reload).to have_attributes(status: "processing", accepted_transfer_recorded_at: nil, provider_accepted_at: nil)
      expect(AuditLog.where(auditable: payout, action: %w[payout.accepted_transfer_recorded payout.reconciled])).to be_empty
      expect(PayoutReturnProof.where(payout: payout)).to be_empty
      # The database cannot stamp an acknowledgement without the marker, and
      # never reverses it, on this ordinary event too.
      expect(PayoutReconciler.classified_event?(payout)).to be(false)
      expect(raw(payout, accepted_transfer_recorded_at: Time.current)).to match(/only in flight/)
      expect(raw(payout, status: Payout.statuses[:reversed], failure_code: nil))
        .to match(/acceptance recorded only in its audit trail/)
      # A later provider result never frees or completes it.
      PayoutCreator.new(settlement: payout.settlement, actor: admin, idempotency_key: payout.idempotency_key)
        .send(:record_submission_outcome!, payout, status: :failed, provider_payout_id: "BANK-EVIDENCE-ONLY",
          failure_code: "provider_returned", initiated_at: Time.current)
      expect(payout.reload).to have_attributes(status: "processing", failure_code: "provider_result_conflict")
      expect(available).to eq(reserved)
    end

    # A2 recheck finding 2 (8132fe22): A1's reconciler recorded such a
    # payout failed on an ordinary event (its generic outcome, no marker to
    # check), the balance rose by its amount and A2 reserved a fresh $10.00.
    # The database now keeps it committed for every writer.
    it "is never failed, reversed, paid, resubmitted, released, deleted or re-identified by any writer" do
      payout = evidence_only!
      reserved = available
      guard = /Accepted transfer fence: payout #{payout.id} has a provider acceptance recorded only in its audit trail/
      # A1's generic failed and reversed outcomes and raw downgrades write
      # these columns straight to the row.
      { "failed" => { status: Payout.statuses[:failed], failure_code: "reconciled_failure" },
        "failed (kept code)" => { status: Payout.statuses[:failed] },
        "reversed" => { status: Payout.statuses[:reversed], failure_code: nil },
        "paid" => { status: Payout.statuses[:paid], paid_at: Time.current, failure_code: nil },
        "pending" => { status: Payout.statuses[:pending] },
        "transfer identifier" => { provider_payout_id: "OTHER-EO" },
        "amount" => { amount_cents: 500 },
        "key" => { idempotency_key: "evidence-only-2" } }.each do |label, columns|
        expect([label, raw(payout, **columns)]).to match([label, guard])
      end
      expect(raw(payout) { Payout.where(id: payout.id).delete_all }).to match(/recorded only in its audit trail; it is never deleted/)
      # No fresh-key reservation of its amount: it stays out of the balance.
      expect(payout.reload).to have_attributes(status: "processing", provider_payout_id: "BANK-EVIDENCE-ONLY")
      expect(available).to eq(reserved)
      expect do
        PayoutCreator.call(settlement: Settlements::Finalizer.call(event: event, actor: admin), actor: admin,
          idempotency_key: "evidence-only-fresh", amount_cents: reserved + 1000)
      end.to raise_error(PayoutCreator::PayoutError, /exceeds the available balance/)
      expect(@calls).to eq(1)
      # A hold keeps it committed; leaving the hold does not.
      EventCancellationRefunds.hold_payouts!(event, actor: admin)
      expect(payout.reload).to have_attributes(status: "held", held_from_status: "processing",
        failure_code: "provider_result_conflict")
      expect(raw(payout, status: Payout.statuses[:processing], held_from_status: nil)).to match(guard)
      expect(raw(payout, status: Payout.statuses[:failed], held_from_status: nil)).to match(guard)
      expect(raw(payout, held_from_status: "pending")).to match(guard)
      expect(payout.reload).to have_attributes(status: "held", provider_payout_id: "BANK-EVIDENCE-ONLY", amount_cents: 1000)
    end

    # On a pending payout too: never submitted (the resend), only held.
    it "keeps a pending one unsent" do
      record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
      payout = PayoutCreator.new(settlement: Settlements::Finalizer.call(event: event, actor: admin), actor: admin,
        idempotency_key: "evidence-only-pending", amount_cents: 1000).send(:reserve!).first
      AuditLogger.record!(action: "payout.provider_result_conflict", auditable: payout, actor: admin,
        organization: organization, event: event, source: "provider", outcome: "unknown",
        metadata: { conflict_reason: PayoutCreator::PAID_REFUSED_REASON })
      guard = /payout #{payout.id} has a provider acceptance recorded only in its audit trail/
      expect(raw(payout, status: Payout.statuses[:processing], provider_payout_id: "manual_po_#{payout.id}")).to match(guard)
      expect(raw(payout, status: Payout.statuses[:failed])).to match(guard)
      # The same key returns it without a submission.
      expect(PayoutCreator.call(settlement: payout.settlement, actor: admin, idempotency_key: "evidence-only-pending"))
        .to eq(payout)
      expect(@calls).to eq(0)
      expect(payout.reload).to be_status_pending
      expect(raw(payout, status: Payout.statuses[:held], held_from_status: "pending")).to eq(:accepted)
    end

    # However it got there (no released writer records one), a persisted
    # recognized conflict on a payout that is no longer committed fails
    # closed: no payout is reserved for its organization under any key. The
    # ordinary failed payout before it (no acceptance) frees and reserves
    # as always.
    it "refuses every new reservation for its organization while one is no longer committed" do
      record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
      settlement = Settlements::Finalizer.call(event: event, actor: admin)
      before_payout = available
      ordinary = PayoutCreator.call(settlement: settlement, actor: admin, idempotency_key: "ordinary-1", amount_cents: 1000)
      PayoutReconciler.call(payout: ordinary.reload, actor: admin, status: "failed", provider_payout_id: ordinary.provider_payout_id,
        evidence: evidence(reason: "Finance never sent the transfer"))
      expect(ordinary.reload).to be_status_failed
      expect(available).to eq(before_payout)
      reissued = PayoutCreator.call(settlement: settlement, actor: admin, idempotency_key: "ordinary-2", amount_cents: 1000)
      expect(reissued.reload).to be_status_processing
      PayoutReconciler.call(payout: reissued, actor: admin, status: "failed", provider_payout_id: reissued.provider_payout_id,
        evidence: evidence(reason: "Finance never sent the transfer"))
      expect(available).to eq(before_payout)

      # The recognized conflict lands on the failed payout (history from
      # before the guard, or a raw write).
      AuditLogger.record!(action: "payout.provider_result_conflict", auditable: reissued, actor: admin,
        organization: organization, event: event, source: "provider", outcome: "unknown",
        metadata: { conflict_reason: PayoutCreator::PAID_REFUSED_REASON })
      expect(PayoutCreator.uncommitted_evidence_only_acceptance?(organization)).to be(true)
      calls = @calls
      expect { PayoutCreator.call(settlement: settlement, actor: admin, idempotency_key: "after-eo", amount_cents: 1000) }
        .to raise_error(PayoutCreator::PayoutError, PayoutCreator::EVIDENCE_ONLY_RESERVATION_MESSAGE)
      expect(@calls).to eq(calls)
      raw_insert = lambda do
        FinancialIntegrity.with_settlement_reader do
          Payout.create!(organization: organization, event: event, settlement: settlement,
            connected_account: reissued.connected_account, provider: "manual", idempotency_key: "raw-after-eo",
            amount_cents: 100, currency: "usd", status: :pending)
        end
      end
      expect(raw(reissued, &raw_insert)).to match(/this organization has a provider acceptance recorded only in its audit trail/)
      # It stays failed: never resurrected or resent either.
      expect(raw(reissued, status: Payout.statuses[:pending])).to match(/payout #{reissued.id} has a provider acceptance/)
      expect(Payout.where(organization: organization).count).to eq(2)
    end
  end
end
