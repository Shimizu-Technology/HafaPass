# frozen_string_literal: true

require "rails_helper"

# A2 recheck finding 1 (758485ae): a transfer the provider accepted after a
# fence, guard or hold refused it is money out with the organizer. The
# database (payouts_accepted_transfer_guard and the commit-time reversal
# check) keeps it committed for every writer and every event: A1 during the
# overlap or after a code rollback writes its generic failed or reversed
# outcome straight to the row, raw SQL does the same. Each is refused, the
# balance stays reserved, and no fresh payout key can send the amount
# again; the current release's exact verified return, after finance records
# the acceptance, releases exactly that amount. Payouts the provider never
# accepted keep their existing outcomes.
RSpec.describe "Accepted transfer fence (database, every writer)" do
  let(:admin) { create(:user, :admin) }
  let(:profile) { create(:organizer_profile, :verified) }
  let(:organization) { profile.organization }
  let(:event) { create(:event, :completed, organization: organization, organizer_profile: profile) }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 2000) }
  let(:fence) { /Accepted transfer fence: payout \d+|Payout reversal fence: payout \d+ is a transfer the provider accepted/ }

  before do
    allow(StripeService).to receive(:verify_payment_context!)
    allow(StripeProcessingFees).to receive(:require_adjustment_review!)
    allow(EmailService).to receive(:send_refund_notification_async)
    allow(Sentry).to receive(:capture_message)
    allow(Sentry).to receive(:capture_exception)
    approved_bank_account!(organization, actor: profile.user, admin: admin)
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

  # The reviewer's fixture: an ordinary event (no never-fulfilled capture);
  # a cancellation hold commits while the gateway call runs, and the
  # (stubbed) provider then reports the $10.00 transfer paid.
  def accepted_while_held!
    record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
    settlement = Settlements::Finalizer.call(event: event, actor: admin)
    # The eligible balance before the payout, independent of its return
    # (CodeRabbit 4706251771): an exact return restores exactly this.
    @available_before_payout = available
    stub_gateway! do |_payout|
      EventCancellationRefunds.hold_payouts!(event, actor: admin)
      PayoutGateway::Result.new(provider_payout_id: "BANK-ACC-HELD", status: :paid)
    end
    payout = PayoutCreator.call(settlement: settlement, actor: admin, idempotency_key: "acc-held", amount_cents: 1000)
    stub_gateway!
    expect(payout.reload).to have_attributes(status: "held", held_from_status: "processing",
      failure_code: "provider_result_conflict", provider_payout_id: "BANK-ACC-HELD")
    expect(payout.provider_accepted_at).to be_present
    expect(ActiveRecord::Base.connection.select_value(
      "SELECT hafapass_event_has_classified_capture(#{event.id})"
    )).to be(false)
    payout
  end

  # A processing accepted transfer: an ordinary refund changes the approved
  # statement of an event with a classified capture while the gateway call
  # runs, then the provider reports it paid.
  def accepted_while_processing!
    order, item, capture = record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
    classified_order, payment, = classified_capture(items: [[1200, 160, 0, 0]], event: event)
    component = create(:fee_component, order: classified_order, order_item: classified_order.order_items.first,
      kind: "processing", amount_cents: 69, estimated: false, provider_reference: "txn_accfence_#{SecureRandom.hex(4)}")
    create(:stripe_fee_evidence, :verified, payment: payment, fee_component: component,
      provider_balance_transaction_id: component.provider_reference)
    settlement = Settlements::Finalizer.call(event: event, actor: admin)
    stub_gateway! do |_payout|
      record_card_refund!(order, item, capture, proceeds_cents: 500)
      PayoutGateway::Result.new(provider_payout_id: "BANK-ACC-PROC", status: :paid)
    end
    payout = PayoutCreator.call(settlement: settlement, actor: admin, idempotency_key: "acc-proc", amount_cents: 1000)
    stub_gateway!
    expect(payout.reload).to have_attributes(status: "processing", failure_code: "provider_result_conflict")
    expect(payout.provider_accepted_at).to be_present
    payout
  end

  # Commit-time checks run inside the spec's transaction.
  def commit_check!
    ActiveRecord::Base.connection.execute("SET CONSTRAINTS payouts_reversal_return_check IMMEDIATE")
  end

  # A write to the row as another release or raw SQL makes it, rolled back.
  # Returns :accepted or the fence message.
  def raw(payout, **columns)
    ActiveRecord::Base.transaction(requires_new: true) do
      yield if block_given?
      Payout.where(id: payout.id).update_all(columns) if columns.any?
      commit_check!
      raise ActiveRecord::Rollback
    end
    :accepted
  rescue ActiveRecord::StatementInvalid => e
    e.message[fence] ? e.message[/(?:Accepted transfer|Payout reversal) fence[^\n]*/] : raise
  end

  # What A1's PayoutReconciler (a0b25ffe) writes for each outcome once the
  # conflict audit is acknowledged; it has no accepted-transfer rule.
  def a1_failed(payout)
    raw(payout, status: Payout.statuses[:failed], failure_code: "reconciled_failure",
      failure_message: "Bank says it never left", updated_at: Time.current)
  end

  def a1_reversed(payout)
    raw(payout, status: Payout.statuses[:reversed], failure_code: nil, failure_message: nil, updated_at: Time.current)
  end

  def a1_paid(payout)
    raw(payout, status: Payout.statuses[:paid], paid_at: Time.current, failure_code: nil, failure_message: nil)
  end

  def every_freeing_writer_refused!(payout, acknowledged:)
    # CodeRabbit 4706251759: the identifier as it was before any attempt.
    transfer = payout.reload.provider_payout_id
    expect(transfer).to be_present
    expect(a1_failed(payout)).to match(/never recorded paid, failed, pending or released/)
    expect(a1_paid(payout)).to match(/never recorded paid, failed, pending or released/)
    expect(a1_reversed(payout)).to match(acknowledged ? /record its return from the current release/ :
      /record the accepted transfer before its return/)
    # A1's PayoutHoldRelease form, a resend, a pending hold origin.
    expect(raw(payout, status: Payout.statuses[:processing], held_from_status: nil, failure_code: nil, failure_message: nil))
      .to match(/never recorded paid/)
    expect(raw(payout, status: Payout.statuses[:pending], held_from_status: nil)).to match(/never recorded paid/)
    expect(raw(payout, status: Payout.statuses[:held], held_from_status: "pending")).to match(/never recorded paid/)
    # Its identity and evidence.
    expect(raw(payout, provider_accepted_at: nil)).to match(/are fixed/)
    expect(raw(payout, provider_payout_id: "OTHER-TRANSFER")).to match(/are fixed/)
    expect(raw(payout, amount_cents: 1)).to match(/are fixed/)
    expect(raw(payout) { Payout.where(id: payout.id).delete_all }).to match(/never deleted/)
    # A reversal with a proof that is not this acceptance's exact return.
    if acknowledged
      wrong_kind = raw(payout, status: Payout.statuses[:reversed], failure_code: nil) do
        raw_return_proof!(payout, kind: "verified_return", returned_at: Time.current, sent_at: payout.provider_accepted_at)
      end
      expect(wrong_kind).to match(/record its return from the current release/)
      wrong_time = raw(payout, status: Payout.statuses[:reversed], failure_code: nil) do
        raw_return_proof!(payout, kind: "accepted_transfer_return", returned_at: Time.current,
          sent_at: payout.provider_accepted_at - 1.minute)
      end
      expect(wrong_time).to match(/record its return from the current release/)
    end
    expect(payout.reload).to have_attributes(failure_code: "provider_result_conflict", provider_payout_id: transfer)
    expect(payout.status).to be_in(%w[processing held])
  end

  def raw_return_proof!(payout, kind:, returned_at:, sent_at:)
    FinancialIntegrity.with_payout_return(payout.id) do
      PayoutReturnProof.create!(payout: payout, kind: kind, returned_amount_cents: payout.confirmed_check_amount_cents,
        returned_at: returned_at, sent_at: sent_at, return_reference_digest: PayoutReturnProof.reference_digest("RET-RAW-#{payout.id}"))
    end
  end

  def fresh_payout!(key, amount_cents)
    PayoutCreator.call(settlement: Settlements::Finalizer.call(event: event, actor: admin), actor: admin,
      idempotency_key: key, amount_cents: amount_cents)
  end

  def conflict(payout)
    AuditLog.where(auditable: payout, action: "payout.provider_result_conflict").order(:id).last
  end

  %i[held processing].each do |state|
    it "keeps a #{state} accepted transfer committed against A1's outcomes and raw SQL, then frees exactly its return" do
      payout = state == :held ? accepted_while_held! : accepted_while_processing!
      reserved_available = available
      calls_after_acceptance = @calls

      every_freeing_writer_refused!(payout, acknowledged: false)
      expect(available).to eq(reserved_available)
      expect { fresh_payout!("acc-fresh-1", 1000) }.to raise_error(PayoutCreator::PayoutError, /available balance|exceeds|must be positive/)

      PayoutReconciler.call(payout: payout.reload, actor: admin, status: "accepted_transfer",
        provider_payout_id: payout.provider_payout_id, evidence: evidence(conflict_audit_id: conflict(payout).id))
      recorded_at = payout.reload.accepted_transfer_recorded_at
      expect(recorded_at).to be_present
      expect(raw(payout, accepted_transfer_recorded_at: recorded_at + 1.day)).to match(/are fixed/)

      every_freeing_writer_refused!(payout, acknowledged: true)
      expect(available).to eq(reserved_available)
      expect { fresh_payout!("acc-fresh-2", 1000) }.to raise_error(PayoutCreator::PayoutError, /available balance|exceeds|must be positive/)
      expect(@calls).to eq(0)
      expect(calls_after_acceptance).to eq(0)

      # The current release's exact verified return is the only way out.
      transfer = payout.reload.provider_payout_id
      PayoutReconciler.call(payout: payout.reload, actor: admin, status: "reversed", provider_payout_id: transfer,
        evidence: evidence(conflict_audit_id: conflict(payout).id, return_reference: "RET-ACC-#{state}",
          returned_amount_cents: payout.disbursement_cents, returned_at: Time.current.utc.iso8601(6)))
      expect { commit_check! }.not_to raise_error
      expect(payout.reload).to have_attributes(status: "reversed", provider_payout_id: transfer,
        accepted_transfer_recorded_at: recorded_at)
      expect(payout.return_proof).to have_attributes(kind: "accepted_transfer_return", sent_at: payout.provider_accepted_at)
      expect(raw(payout, status: Payout.statuses[:processing], failure_code: "provider_result_conflict")).to match(/stays reversed/)
      expect(raw(payout, provider_accepted_at: nil)).to match(/are fixed/)
      if state == :held
        # The ordinary event's balance is back to exactly what it was before
        # the payout: the $10.00 returned and the conflict's freeze lifted,
        # nothing more.
        expect(available).to eq(@available_before_payout)
        expect(fresh_payout!("acc-fresh-3", 1000)).to be_persisted
        expect(@calls).to eq(1)
      end
    end
  end

  # CodeRabbit 4705527035: the conflict audit is written fail-open after the
  # held update. When that write fails (or retention later redacts every
  # audit row), the durable marker alone keeps every protection, and
  # finance's acknowledgement of it still books the cash out once in CPA.
  it "keeps the acceptance and every protection when the fail-open conflict audit is never written, then redacted" do
    allow(AuditLogger).to receive(:write!).and_wrap_original do |original, **attributes|
      raise ActiveRecord::StatementInvalid, "simulated audit outage" if attributes[:action] == "payout.provider_result_conflict"

      original.call(**attributes)
    end
    payout = accepted_while_held!
    expect(conflict(payout)).to be_nil
    expect(AuditWriteFailure.where(action: "payout.provider_result_conflict", auditable_id: payout.id)).to exist
    expect(PayoutCreator.provider_accepted?(payout)).to be(true)
    reserved_available = available

    # A later provider result (paid again, or failed) never makes it ordinary,
    # downgrades it or frees it: it is ignored on the marker.
    observer = PayoutCreator.new(settlement: payout.settlement, actor: admin, idempotency_key: payout.idempotency_key)
    observer.send(:record_submission_outcome!, payout.reload, status: :paid, provider_payout_id: "BANK-ACC-HELD",
      paid_at: Time.current, initiated_at: Time.current)
    observer.send(:record_submission_outcome!, payout.reload, status: :failed, provider_payout_id: "BANK-ACC-HELD",
      failure_code: "provider_returned", initiated_at: Time.current)
    expect(payout.reload).to have_attributes(status: "held", held_from_status: "processing", failure_code: "provider_result_conflict")
    expect(AuditLog.where(auditable: payout, action: "payout.late_result_ignored").count).to eq(2)
    expect { PayoutHoldRelease.call(payout: payout, actor: admin) }.to raise_error(PayoutHoldRelease::ReleaseError)
    every_freeing_writer_refused!(payout, acknowledged: false)
    expect do
      PayoutReconciler.call(payout: payout.reload, actor: admin, status: "failed", provider_payout_id: payout.provider_payout_id,
        evidence: evidence(reason: "Finance believes it never left"))
    end.to raise_error(PayoutReconciler::ReconciliationError, PayoutReconciler::ACCEPTED_NOT_FAILED_MESSAGE)
    expect { fresh_payout!("acc-noaudit-fresh", 1000) }.to raise_error(PayoutCreator::PayoutError, /available balance|exceeds|must be positive/)
    expect(@calls).to eq(0)
    expect(available).to eq(reserved_available)

    # There is no audit to name: an invented id is refused, and the
    # acknowledgement of the durable acceptance records the cash fact.
    expect do
      PayoutReconciler.call(payout: payout.reload, actor: admin, status: "accepted_transfer",
        provider_payout_id: payout.provider_payout_id, evidence: evidence(conflict_audit_id: 999_999))
    end.to raise_error(PayoutReconciler::ReconciliationError, /acknowledge the latest provider conflict/)
    acceptance = evidence
    PayoutReconciler.call(payout: payout.reload, actor: admin, status: "accepted_transfer",
      provider_payout_id: payout.provider_payout_id, evidence: acceptance)
    recorded = AuditLog.where(auditable: payout, action: "payout.accepted_transfer_recorded").sole
    expect(recorded.metadata).to include("conflict_audit_id" => nil,
      "acknowledged_marker" => { "provider_accepted_at" => payout.reload.provider_accepted_at.utc.iso8601(6) })
    expect(payout.accepted_transfer_recorded_at).to be_present
    month = Time.current.in_time_zone("Pacific/Guam")
    cpa = -> { CpaMonthlyReport.new(month.year, month.month).report }
    report = cpa.call
    expect(report[:accepted_transfers].map { |entry| entry[:payout_id] }).to eq([payout.id])
    expect(report[:rows].find { |row| row[:event_id] == event.id }).to include(organizer_payouts_made_cents: 1000,
      payout_reversals_cents: 0)

    # Retention redacts every audit row of the payout: the marker still holds.
    AuditLog.redact!(AuditLog.where(auditable: payout), { ip_address: nil, before_data: {}, after_data: {}, metadata: {},
      retention_anonymized_at: Time.current, updated_at: Time.current })
    expect(PayoutCreator.provider_accepted?(payout.reload)).to be(true)
    every_freeing_writer_refused!(payout, acknowledged: true)
    expect(available).to eq(reserved_available)
    expect(cpa.call[:rows].find { |row| row[:event_id] == event.id }).to include(organizer_payouts_made_cents: 1000)

    # The exact return frees exactly its amount, once.
    PayoutReconciler.call(payout: payout.reload, actor: admin, status: "reversed", provider_payout_id: payout.provider_payout_id,
      evidence: evidence(return_reference: "RET-ACC-NOAUDIT", returned_amount_cents: payout.disbursement_cents,
        returned_at: Time.current.utc.iso8601(6)))
    expect { commit_check! }.not_to raise_error
    expect(payout.reload).to be_status_reversed
    expect(payout.return_proof).to have_attributes(kind: "accepted_transfer_return", sent_at: payout.provider_accepted_at)
    # The ordinary event's balance is back to exactly its value before the
    # payout (the $10.00 returned and the open conflict's freeze lifted).
    expect(available).to eq(@available_before_payout)
    expect(@available_before_payout).to be >= reserved_available + 1000
    expect(cpa.call[:rows].find { |row| row[:event_id] == event.id }).to include(organizer_payouts_made_cents: 1000,
      payout_reversals_cents: 1000)
    # CodeRabbit 4705527061: the redacted acceptance can no longer be
    # compared, so even the same request is refused rather than replayed.
    expect do
      PayoutReconciler.call(payout: payout.reload, actor: admin, status: "accepted_transfer",
        provider_payout_id: payout.provider_payout_id, evidence: acceptance)
    end.to raise_error(PayoutReconciler::ReconciliationError, /already recorded with different evidence/)
    expect(AuditLog.where(auditable: payout, action: "payout.accepted_transfer_recorded").count).to eq(1)
  end

  it "replays an identical acceptance after the verified return and refuses different evidence (4705527061)" do
    payout = accepted_while_held!
    acceptance = evidence(conflict_audit_id: conflict(payout).id)
    PayoutReconciler.call(payout: payout.reload, actor: admin, status: "accepted_transfer",
      provider_payout_id: payout.provider_payout_id, evidence: acceptance)
    PayoutReconciler.call(payout: payout.reload, actor: admin, status: "reversed", provider_payout_id: payout.provider_payout_id,
      evidence: evidence(conflict_audit_id: conflict(payout).id, return_reference: "RET-ACC-REPLAY",
        returned_amount_cents: payout.disbursement_cents, returned_at: Time.current.utc.iso8601(6)))
    expect(payout.reload).to have_attributes(status: "reversed", failure_code: nil)
    expect do
      expect(PayoutReconciler.call(payout: payout.reload, actor: admin, status: "accepted_transfer",
        provider_payout_id: payout.provider_payout_id, evidence: acceptance)).to eq(payout)
    end.not_to(change { AuditLog.where(auditable: payout, action: "payout.accepted_transfer_recorded").count })
    expect do
      PayoutReconciler.call(payout: payout.reload, actor: admin, status: "accepted_transfer",
        provider_payout_id: payout.provider_payout_id, evidence: acceptance.merge(reason: "Another confirmation"))
    end.to raise_error(PayoutReconciler::ReconciliationError, /already recorded with different evidence/)
    expect do
      PayoutReconciler.call(payout: payout.reload, actor: admin, status: "accepted_transfer",
        provider_payout_id: "OTHER-TRANSFER", evidence: acceptance)
    end.to raise_error(PayoutReconciler::ReconciliationError, /already recorded with different evidence/)
  end

  it "refuses a full bank account number in the acceptance evidence before any audit (4705527049)" do
    payout = accepted_while_held!
    number = payout.connected_account.bank_account_number
    expect do
      PayoutReconciler.call(payout: payout.reload, actor: admin, status: "accepted_transfer",
        provider_payout_id: payout.provider_payout_id,
        evidence: evidence(conflict_audit_id: conflict(payout).id, reason: "Left account #{number}"))
    end.to raise_error(PayoutReconciler::ReconciliationError, "Leave full bank account numbers out of payout evidence")
    expect(AuditLog.where(auditable: payout, action: "payout.accepted_transfer_recorded")).to be_empty
    expect(payout.reload.accepted_transfer_recorded_at).to be_nil
  end

  it "records the acceptance only in flight, with its transfer identifier and conflict" do
    record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
    stub_gateway!
    payout = fresh_payout!("not-accepted", 1000)
    expect(raw(payout, provider_accepted_at: Time.current, failure_code: nil)).to match(/only in flight/)
    expect(raw(payout, accepted_transfer_recorded_at: Time.current)).to match(/only in flight/)
    expect do
      ActiveRecord::Base.transaction(requires_new: true) do
        Payout.create!(payout.attributes.except("id", "idempotency_key", "provider_payout_id")
          .merge("idempotency_key" => "inserted-accepted", "provider_accepted_at" => Time.current))
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /recorded only on the payout that was submitted/)
  end

  it "leaves payouts the provider never accepted on their existing outcomes" do
    record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
    stub_gateway!
    in_flight = fresh_payout!("ordinary-failed", 1000)
    expect(a1_failed(in_flight)).to eq(:accepted)
    PayoutReconciler.call(payout: in_flight.reload, actor: admin, status: "failed", provider_payout_id: in_flight.provider_payout_id,
      evidence: evidence(reason: "Finance never sent the transfer"))
    expect(in_flight.reload).to be_status_failed

    sent = fresh_payout!("ordinary-paid", 1000)
    PayoutReconciler.call(payout: sent.reload, actor: admin, status: "paid", provider_payout_id: "BANK-ORD-1", evidence: evidence)
    expect(sent.reload).to be_status_paid
    # An ordinary event keeps A1's generic reversal accounting.
    expect(a1_reversed(sent)).to eq(:accepted)
    PayoutReconciler.call(payout: sent.reload, actor: admin, status: "reversed", provider_payout_id: "BANK-ORD-1",
      evidence: evidence)
    expect { commit_check! }.not_to raise_error
    expect(sent.reload).to be_status_reversed
  end
end
