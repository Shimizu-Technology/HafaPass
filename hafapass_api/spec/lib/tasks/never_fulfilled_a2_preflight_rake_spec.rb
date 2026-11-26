# frozen_string_literal: true

require "rails_helper"
require "rake"

# Read-only A2 preflight (docs/NEVER_FULFILLED_RELEASE.md "A2 release"): the
# guards, the undisposed counts, custody completeness and the organizer
# payable audit of each event with a classified capture, with the action the
# guards leave open for each in-flight payout. Writes nothing.
RSpec.describe "never_fulfilled:a2_preflight" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("never_fulfilled:a2_preflight")
  end

  let(:admin) { create(:user, :admin) }
  let(:profile) { create(:organizer_profile, :verified) }
  let(:organization) { profile.organization }
  let(:event) { create(:event, :completed, organization: organization, organizer_profile: profile) }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 2000) }

  before do
    allow(StripeProcessingFees).to receive(:require_adjustment_review!)
    allow(PayoutGateway).to receive(:submit) { |payout| PayoutGateway::Result.new(provider_payout_id: "manual_po_#{payout.id}", status: :processing) }
    approved_bank_account!(organization, actor: profile.user, admin: admin)
  end

  def run_task
    task = Rake::Task["never_fulfilled:a2_preflight"]
    task.reenable
    captured = StringIO.new
    $stdout = captured
    task.invoke
    captured.string
  ensure
    $stdout = STDOUT
  end

  def lines(output, section) = output.lines.grep(/\Asection=#{section}\t/).map { |line| line.strip.split("\t").to_h { |pair| pair.split("=", 2) } }

  it "uses the full paid cutoff for dated statement changes and escalates undated evidence" do
    record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
    payout = PayoutCreator.call(settlement: Settlements::Finalizer.call(event: event, actor: admin), actor: admin,
      idempotency_key: "pf-statement-cutoff", amount_cents: 1000)
    classified_capture(items: [[1200, 160, 0, 0]], event: event)
    submitted_at = AuditLog.where(auditable: payout, action: "payout.submission_requested").sole.occurred_at
    cutoff_at = submitted_at - 1.minute
    allow(Commerce::NeverFulfilledPayoutHold).to receive(:block_started_at).and_return(nil)
    allow(PayoutEntryGuard).to receive(:paid_cutoff).and_return(
      { cutoff_at: cutoff_at, restated_at: nil, unproven: [] })

    row = lines(run_task, "payout").sole
    expect(row).to include("restated_at" => "none", "paid_cutoff_at" => cutoff_at.utc.iso8601(6), "escalate" => "if_sent")
    expect(row.fetch("action")).to include("prior-send exception is unavailable")

    allow(PayoutEntryGuard).to receive(:paid_cutoff).and_return(
      { cutoff_at: nil, restated_at: nil, unproven: [{ reason: "missing_time" }] })
    row = lines(run_task, "payout").sole
    expect(row).to include("paid_cutoff_at" => "none", "escalate" => "if_sent")
    expect(row.fetch("action")).to include("audited finance disposition")
  end

  it "uses the earlier event hold for the prior-send exception" do
    record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
    payout = PayoutCreator.call(settlement: Settlements::Finalizer.call(event: event, actor: admin), actor: admin,
      idempotency_key: "pf-paid-hold-cutoff", amount_cents: 1000)
    classified_capture(items: [[1200, 160, 0, 0]], event: event)
    submitted_at = AuditLog.where(auditable: payout, action: "payout.submission_requested").sole.occurred_at
    hold_at = submitted_at + 1.minute
    restated_at = submitted_at + 2.minutes
    allow(Commerce::NeverFulfilledPayoutHold).to receive(:block_started_at).with(event).and_return(hold_at)
    allow(PayoutEntryGuard).to receive(:paid_cutoff).and_return(
      { cutoff_at: restated_at, restated_at: restated_at, unproven: [] })

    row = lines(run_task, "payout").sole
    expect(row).to include("paid_cutoff_at" => hold_at.utc.iso8601(6), "escalate" => "if_sent_after")
    expect(row.fetch("action")).to include("before #{hold_at.utc.iso8601(6)} and sent_before_hold_confirmed")
    expect(row.fetch("action")).not_to include("sent_before_restatement_confirmed")
  end

  it "lists stale in-flight payouts and their action, the payable audit and the gates, and writes nothing" do
    record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
    sent = PayoutCreator.call(settlement: Settlements::Finalizer.call(event: event, actor: admin), actor: admin,
      idempotency_key: "pf-sent", amount_cents: 2000)
    pending = PayoutCreator.new(settlement: Settlements::Finalizer.call(event: event, actor: admin), actor: admin,
      idempotency_key: "pf-pending", amount_cents: 1000).send(:reserve!).first
    order, payment, = classified_capture(items: [[1200, 160, 0, 0]], event: event)
    component = create(:fee_component, order: order, order_item: order.order_items.first, kind: "processing",
      amount_cents: 69, estimated: false, provider_reference: "txn_pf_#{SecureRandom.hex(4)}")
    create(:stripe_fee_evidence, :verified, payment: payment, fee_component: component,
      provider_balance_transaction_id: component.provider_reference)
    counts = -> { [AuditLog.count, Settlement.count, Payout.count, PayoutCustodyDetermination.count] }
    before = counts.call

    output = run_task
    expect(counts.call).to eq(before)
    expect(lines(output, "guards").sole).to include("payouts_require_custody" => "true", "reader_rule_current" => "true")
    expect(lines(output, "undisposed").sole).to include("gate_zero_undisposed" => "PASS")
    expect(lines(output, "custody").sole).to include("undetermined_paid_payouts" => "0")
    expect(lines(output, "event").sole).to include("event_id" => event.id.to_s, "needs_finalizing" => "yes",
      "reserved_cents" => "3000", "sent_cents" => "0", "latest_reader" => "nfc-a2")
    rows = lines(output, "payout").index_by { |row| row["payout_id"] }
    expect(rows.fetch(sent.id.to_s)).to include("current" => "false", "submitted" => "true",
      "restated_at" => payment.reload.capture_recorded_at.utc.iso8601(6))
    expect(rows.fetch(sent.id.to_s)["action"]).to start_with("record paid only with transfer evidence before")
    expect(rows.fetch(pending.id.to_s)).to include("submitted" => "false", "action" => "not sent: fail and reissue on a new version")
  end

  # CodeRabbit 4707205586 / 4707205572: a payout whose only submission is
  # after the restatement may have left (finance sends a manual transfer
  # after the placeholder), so it is never reported unsent; an accepted
  # transfer gets its own action before any version rule.
  it "never reports a post-cutoff submission unsent, and gives accepted transfers their own action" do
    record_card_sale!(event, ticket_type: ticket_type, quantity: 10)
    late = PayoutCreator.call(settlement: Settlements::Finalizer.call(event: event, actor: admin), actor: admin,
      idempotency_key: "pf-late", amount_cents: 1000)
    audit_only = PayoutCreator.call(settlement: Settlements::Finalizer.call(event: event, actor: admin), actor: admin,
      idempotency_key: "pf-audit-only", amount_cents: 1000)
    marked = PayoutCreator.call(settlement: Settlements::Finalizer.call(event: event, actor: admin), actor: admin,
      idempotency_key: "pf-marked", amount_cents: 1000)
    unsent = PayoutCreator.new(settlement: Settlements::Finalizer.call(event: event, actor: admin), actor: admin,
      idempotency_key: "pf-unsent", amount_cents: 1000).send(:reserve!).first
    submitted_at = AuditLog.where(auditable: late, action: "payout.submission_requested").sole.occurred_at
    order, payment, = classified_capture(items: [[1200, 160, 0, 0]], event: event)
    component = create(:fee_component, order: order, order_item: order.order_items.first, kind: "processing",
      amount_cents: 69, estimated: false, provider_reference: "txn_pfl_#{SecureRandom.hex(4)}")
    create(:stripe_fee_evidence, :verified, payment: payment, fee_component: component,
      provider_balance_transaction_id: component.provider_reference)
    # The capture was recorded before the late payout's submission (an
    # overlap capture classified afterwards), so its restatement predates it.
    stamp!(payment, :capture_recorded_at, submitted_at - 1.hour, trigger: "payments_capture_recorded_at")
    connection = ActiveRecord::Base.connection
    connection.execute("ALTER TABLE never_fulfilled_captures DISABLE TRIGGER never_fulfilled_captures_append_only")
    UnfulfilledCapture.where(payment_id: payment.id).update_all(capture_recorded_at: submitted_at - 1.hour)
    connection.execute("ALTER TABLE never_fulfilled_captures ENABLE TRIGGER never_fulfilled_captures_append_only")
    # The provider then reports marked's transfer paid: refused by the
    # restatement, kept as its accepted transfer (the durable marker).
    PayoutCreator.new(settlement: marked.settlement, actor: admin, idempotency_key: marked.idempotency_key)
      .send(:record_submission_outcome!, marked.reload, status: :paid, provider_payout_id: "BANK-PF-MARKED",
        initiated_at: Time.current)
    expect(marked.reload.provider_accepted_at).to be_present
    Payout.where(id: audit_only.id).update_all(failure_code: "provider_result_conflict")
    AuditLogger.record!(action: "payout.provider_result_conflict", auditable: audit_only.reload, actor: admin,
      organization: organization, event: event, source: "provider", outcome: "unknown",
      metadata: { conflict_reason: PayoutCreator::PAID_REFUSED_REASON })

    output = run_task
    rows = lines(output, "payout").index_by { |row| row["payout_id"] }
    late_row = rows.fetch(late.id.to_s)
    expect(late_row).to include("current" => "false", "submitted" => "true", "acceptance" => "none", "escalate" => "if_sent")
    expect(Time.iso8601(late_row["restated_at"])).to be < submitted_at
    expect(late_row["action"]).to start_with("submitted after #{late_row['restated_at']}")
      .and include("prior-send exception is unavailable", "check the bank first", "if it left, keep it committed and escalate")
    expect(rows.fetch(late.id.to_s)["action"]).not_to include("not sent")
    expect(rows.fetch(audit_only.id.to_s)).to include("acceptance" => "audit_only", "escalate" => "yes",
      "action" => a_string_starting_with("accepted (audit trail only): do not send, fail, reverse or reissue"))
    expect(rows.fetch(marked.id.to_s)).to include("acceptance" => "marked", "escalate" => "no",
      "action" => a_string_starting_with("accepted transfer: it left; do not send, fail or reissue; record accepted_transfer"))
    expect(rows.fetch(unsent.id.to_s)).to include("submitted" => "false", "acceptance" => "none",
      "action" => "not sent: fail and reissue on a new version")
    expect(lines(output, "accepted").sole).to include("marked" => "1", "acknowledged" => "0", "evidence_only" => "1",
      "evidence_only_payout_ids" => audit_only.id.to_s)
  end

  # CodeRabbit 4707205566: the marker column is probed on its own, so a
  # partially applied schema (the custody table missing) still counts a
  # marked payout with a paid-refusal audit as marked, not evidence-only.
  it "counts a marked acceptance as marked when another A2 object is missing" do
    record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
    allow(PayoutGateway).to receive(:submit) do |_payout|
      EventCancellationRefunds.hold_payouts!(event, actor: admin)
      PayoutGateway::Result.new(provider_payout_id: "BANK-PF-PARTIAL", status: :paid)
    end
    allow(EmailService).to receive(:send_refund_notification_async)
    payout = PayoutCreator.call(settlement: Settlements::Finalizer.call(event: event, actor: admin), actor: admin,
      idempotency_key: "pf-partial", amount_cents: 1000)
    expect(payout.reload.provider_accepted_at).to be_present
    output = nil
    ActiveRecord::Base.transaction(requires_new: true) do
      ActiveRecord::Base.connection.execute("ALTER TABLE payout_custody_determinations RENAME TO spec_partial_custody")
      ActiveRecord::Base.connection.clear_cache!
      output = run_task
      raise ActiveRecord::Rollback
    end
    ActiveRecord::Base.connection.clear_cache!
    expect(lines(output, "schema").sole).to include("state" => "pre_a2", "missing" => "payout_custody_determinations")
    expect(lines(output, "accepted").sole).to include("marked" => "1", "evidence_only" => "0",
      "evidence_only_payout_ids" => "none", "gate_evidence_only_zero" => "PASS")
  end

  # CodeRabbit 4703321691: a disabled trigger keeps its pg_trigger row.
  # CodeRabbit 4704013181 (runbook step 8): a never-sent payout on a version
  # without the capture's $0 line defeats the P4 proof of an open
  # over-return, so finalizing first is refused. Finance confirms no transfer
  # left, fails the reservation, reruns preflight, then finalizes and
  # reissues on the new version.
  it "clears a stale never-sent reservation before re-finalizing when it blocks the proof" do
    allow(EmailService).to receive(:send_refund_notification_async)
    allow(StripeService).to receive(:verify_payment_context!)
    record_card_sale!(event, ticket_type: ticket_type, quantity: 5, processing_fee_cents: 100)
    stale = PayoutCreator.call(settlement: Settlements::Finalizer.call(event: event, actor: admin), actor: admin,
      idempotency_key: "pf-stale", amount_cents: 1000)
    expect(stale.reload).to have_attributes(status: "processing", provider_payout_id: "manual_po_#{stale.id}")
    order, payment, capture = classified_capture(items: [[1200, 160, 0, 0]], event: event)
    component = create(:fee_component, order: order, order_item: order.order_items.first, kind: "processing",
      amount_cents: 69, estimated: false, provider_reference: "txn_pfs_#{SecureRandom.hex(4)}")
    create(:stripe_fee_evidence, :verified, payment: payment, fee_component: component,
      provider_balance_transaction_id: component.provider_reference)
    ingest_provider_refund!(payment, 1360, id: "re_pfs_#{SecureRandom.hex(3)}")
    lose_dispute!(payment, "dp_pfs_#{SecureRandom.hex(3)}", amount: 1360)
    Commerce::NeverFulfilledResolution.evaluate!(capture.reload, trigger: "spec")
    expect(ReconciliationException.open.where(payment: payment, code: "never_fulfilled_buyer_overpaid")).to exist

    output = run_task
    expect(lines(output, "event").sole).to include("needs_finalizing" => "yes")
    # Submitted (a manual placeholder) before the restatement: only the bank
    # can say whether it left.
    expect(lines(output, "payout").sole).to include("payout_id" => stale.id.to_s, "submitted" => "true",
      "acceptance" => "none", "escalate" => "if_sent_after",
      "action" => a_string_including("if the bank confirms it never left, fail and reissue; if it left at or after then, keep it committed and escalate"))
    expect(Commerce::NeverFulfilledPayoutHold.blocked?(event)).to be(true)
    expect { Settlements::Finalizer.call(event: event, actor: admin) }
      .to raise_error(Settlements::Finalizer::FinalizationError, /Resolve open reconciliation exceptions/)

    # The bank confirms nothing left: the reservation fails (no return
    # evidence, since no money moved).
    PayoutReconciler.call(payout: stale, actor: admin, status: "failed", provider_payout_id: stale.provider_payout_id,
      evidence: { reference: "Bank shows no transfer", reason: "Never sent to the bank",
        confirmed_at: Time.current.utc.iso8601(6) })
    expect(stale.reload).to be_status_failed
    expect(Commerce::NeverFulfilledPayoutHold.blocked?(event)).to be(false)
    rerun = run_task
    expect(lines(rerun, "payout")).to be_empty
    expect(lines(rerun, "event").sole).to include("needs_finalizing" => "yes", "reserved_cents" => "0")

    reissued = PayoutCreator.call(settlement: Settlements::Finalizer.call(event: event, actor: admin), actor: admin,
      idempotency_key: "pf-reissue", amount_cents: 1000)
    expect(reissued.reload).to be_status_processing
    expect(lines(run_task, "event").sole).to include("needs_finalizing" => "no")
  end

  # CodeRabbit 4706251688: every acceptance carries its durable marker; one
  # shown only by its conflict audit fails the gate and is named.
  it "counts accepted transfers and fails the gate on an acceptance shown only by its audit" do
    record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
    payout = PayoutCreator.call(settlement: Settlements::Finalizer.call(event: event, actor: admin), actor: admin,
      idempotency_key: "preflight-evidence-only", amount_cents: 1000)
    expect(lines(run_task, "accepted").sole).to include("marked" => "0", "evidence_only" => "0",
      "evidence_only_payout_ids" => "none", "gate_evidence_only_zero" => "PASS")
    AuditLogger.record!(action: "payout.provider_result_conflict", auditable: payout, actor: admin,
      organization: organization, event: event, source: "provider", outcome: "unknown",
      metadata: { conflict_reason: PayoutCreator::PAID_REFUSED_REASON })
    expect(lines(run_task, "accepted").sole).to include("evidence_only" => "1", "evidence_only_payout_ids" => payout.id.to_s,
      "gate_evidence_only_zero" => "FAIL (escalate each to finance)")
  end

  # A2 recheck finding 3 (8132fe22): the runbook's first run is before the
  # migration, on A1's schema, where the task aborted at
  # hafapass_overpaid_platform_only. A2's columns, tables and functions are
  # renamed away here in a rolled-back transaction, so any reference to one
  # fails the run (the overlap rehearsal runs it on A1's exact schema).
  it "runs read-only on the A1 schema before the migration and names what only the migration provides" do
    record_card_sale!(event, ticket_type: ticket_type, quantity: 5)
    sent = PayoutCreator.call(settlement: Settlements::Finalizer.call(event: event, actor: admin), actor: admin,
      idempotency_key: "pre-sent", amount_cents: 2000)
    pending = PayoutCreator.new(settlement: Settlements::Finalizer.call(event: event, actor: admin), actor: admin,
      idempotency_key: "pre-pending", amount_cents: 1000).send(:reserve!).first
    order, payment, = classified_capture(items: [[1200, 160, 0, 0]], event: event)
    component = create(:fee_component, order: order, order_item: order.order_items.first, kind: "processing",
      amount_cents: 69, estimated: false, provider_reference: "txn_pre_#{SecureRandom.hex(4)}")
    create(:stripe_fee_evidence, :verified, payment: payment, fee_component: component,
      provider_balance_transaction_id: component.provider_reference)
    AuditLogger.record!(action: "payout.provider_result_conflict", auditable: pending, actor: admin,
      organization: organization, event: event, source: "provider", outcome: "unknown",
      metadata: { conflict_reason: PayoutCreator::PAID_REFUSED_REASON })
    connection = ActiveRecord::Base.connection
    output = nil
    ActiveRecord::Base.transaction(requires_new: true) do
      connection.execute(<<~SQL)
        ALTER TABLE payouts RENAME COLUMN provider_accepted_at TO spec_a1_1;
        ALTER TABLE payouts RENAME COLUMN provider_accepted_basis TO spec_a1_2;
        ALTER TABLE payouts RENAME COLUMN accepted_transfer_recorded_at TO spec_a1_3;
        ALTER TABLE settlements RENAME COLUMN finalized_reader TO spec_a1_4;
        ALTER TABLE settlements RENAME COLUMN finalized_recorded_at TO spec_a1_5;
        ALTER TABLE settlements RENAME COLUMN reader_digest TO spec_a1_6;
        ALTER TABLE reconciliation_exceptions RENAME COLUMN proof_checked_at TO spec_a1_7;
        ALTER TABLE stripe_fee_evidences RENAME COLUMN facts_recorded_at TO spec_a1_8;
        ALTER TABLE payout_custody_determinations RENAME TO spec_a1_custody;
        ALTER TABLE payout_return_proofs RENAME TO spec_a1_proofs;
        ALTER FUNCTION hafapass_overpaid_platform_only(bigint) RENAME TO spec_a1_f1;
        ALTER FUNCTION hafapass_settlement_restated_at(bigint) RENAME TO spec_a1_f2;
        ALTER FUNCTION hafapass_event_has_classified_capture(bigint) RENAME TO spec_a1_f3;
        ALTER FUNCTION hafapass_overpaid_proof_facts(bigint) RENAME TO spec_a1_f4;
        ALTER FUNCTION hafapass_payout_acceptance_audited(bigint) RENAME TO spec_a1_f5;
      SQL
      connection.clear_cache!
      output = run_task
      raise ActiveRecord::Rollback
    end
    connection.clear_cache!

    expect(lines(output, "snapshot").sole).to include("read_only" => "on")
    expect(lines(output, "schema").sole).to include("state" => "pre_a2")
    expect(lines(output, "schema").sole["missing"].split(",")).to include("payouts.provider_accepted_at",
      "settlements.finalized_reader", "stripe_fee_evidences.facts_recorded_at", "payout_custody_determinations",
      "hafapass_overpaid_platform_only()", "hafapass_settlement_restated_at()")
    guards = lines(output, "guards").sole
    expect(guards).to include("gate_guards" => "FAIL", "hafapass_settlement_restated_at" => "false", "reader_rule_current" => "true")
    expect(guards["failing_guards"].split(",")).to include("hafapass_settlement_restated_at", "hafapass_payout_acceptance_audited")
    expect(lines(output, "undisposed").sole).to include("gate_zero_undisposed" => "PASS")
    expect(lines(output, "holds").sole).to include("overpaid_proven" => "after_migration")
    # Before the migration every such audit is evidence-only (no marker column).
    expect(lines(output, "accepted").sole).to include("marked" => "0", "evidence_only" => "1",
      "evidence_only_payout_ids" => pending.id.to_s, "gate_evidence_only_zero" => "FAIL (escalate each to finance)")
    expect(lines(output, "custody").sole).to include("undetermined_paid_payouts" => "after_migration",
      "gate_custody_complete" => a_string_starting_with("FAIL (pre-migration"))
    expect(lines(output, "event").sole).to include("event_id" => event.id.to_s, "latest_reader" => "pre_a2",
      "needs_finalizing" => "yes", "reserved_cents" => "3000", "sent_cents" => "0", "current_payable_cents" => "after_migration",
      "remaining_cents" => "after_migration", "over_committed" => "after_migration",
      "organization_available_cents" => "after_migration")
    rows = lines(output, "payout").index_by { |row| row["payout_id"] }
    expect(rows.fetch(sent.id.to_s)).to include("current" => "false", "submitted" => "true", "restated_at" => "after_migration",
      "settlement_reader" => "pre_a2", "acceptance" => "none", "escalate" => "if_sent_after",
      "action" => a_string_starting_with("record paid only with transfer evidence before"))
    # CodeRabbit 4707205572: its paid-refusal audit (no marker column yet)
    # makes it an audit-only acceptance: escalated, never failed or reissued.
    expect(rows.fetch(pending.id.to_s)).to include("current" => "false", "submitted" => "false",
      "acceptance" => "audit_only", "escalate" => "yes", "action" => a_string_starting_with("accepted (audit trail only)"))

    # After the migration (the real schema again) the same data reads with
    # the A2 reader and every guard is inspected.
    after = run_task
    expect(lines(after, "schema").sole).to include("state" => "a2", "missing" => "none")
    expect(lines(after, "guards").sole).to include("payouts_audited_acceptance_guard" => "true",
      "hafapass_payout_acceptance_audited" => "true", "audit_logs_keep_acceptance_conflict" => "true",
      "hafapass_organization_acceptance_uncommitted" => "true", "reader_rule_current" => "true")
    expect(lines(after, "event").sole).to include("latest_reader" => "nfc-a2", "needs_finalizing" => "yes")
    expect(lines(after, "event").sole["current_payable_cents"]).to match(/\A-?\d+\z/)
    expect(lines(after, "payout").index_by { |row| row["payout_id"] }.fetch(sent.id.to_s)["restated_at"])
      .to eq(payment.reload.capture_recorded_at.utc.iso8601(6))
  end

  it "fails the guard gate when a required trigger exists but is disabled" do
    ActiveRecord::Base.connection.execute("INSERT INTO financial_cutovers (key) VALUES " \
      "('#{FinancialIntegrity::PAYOUT_ENTRY_CUTOVER}') ON CONFLICT (key) DO NOTHING")
    expect(lines(run_task, "guards").sole).to include("payouts_require_custody" => "true", "gate_guards" => "PASS")
    ActiveRecord::Base.connection.execute("ALTER TABLE payouts DISABLE TRIGGER payouts_require_custody")
    expect(lines(run_task, "guards").sole).to include("payouts_require_custody" => "false", "gate_guards" => "FAIL")
  end

  # A2 recheck finding 2 (758485ae): the reviewer disabled both reversal
  # triggers, the return proof's insert and commit checks and the frozen
  # settlement guard and still saw PASS. Each required guard, disabled on
  # its own, now fails the gate and is named.
  describe "every required money guard" do
    before do
      ActiveRecord::Base.connection.execute("INSERT INTO financial_cutovers (key) VALUES " \
        "('#{FinancialIntegrity::PAYOUT_ENTRY_CUTOVER}') ON CONFLICT (key) DO NOTHING")
    end

    # The guards line with the schema change applied, then rolled back.
    def with_change(sql)
      result = nil
      ActiveRecord::Base.transaction(requires_new: true) do
        ActiveRecord::Base.connection.execute(sql)
        result = lines(run_task, "guards").sole
        raise ActiveRecord::Rollback
      end
      result
    end

    it "lists the schema's every hafapass_* trigger with its table and function" do
      present = ActiveRecord::Base.connection.select_rows(<<~SQL).to_h { |name, table, function| [name, [table, function]] }
        SELECT t.tgname, c.relname, p.proname FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
          JOIN pg_proc p ON p.oid = t.tgfoid WHERE NOT t.tgisinternal AND p.proname LIKE 'hafapass\\_%'
      SQL
      expect(FinancialIntegrity::PREFLIGHT_TRIGGERS).to eq(present)
      guards = lines(run_task, "guards").sole
      expect(guards).to include("gate_guards" => "PASS", "failing_guards" => "none",
        "required_guards" => (present.size + FinancialIntegrity::PREFLIGHT_FUNCTIONS.size + 1).to_s)
    end

    it "fails the gate when any one of them is disabled" do
      FinancialIntegrity::PREFLIGHT_TRIGGERS.each do |name, (table, _function)|
        result = with_change("ALTER TABLE #{table} DISABLE TRIGGER #{name}")
        expect([name, result[name], result["gate_guards"], result["failing_guards"]]).to eq([name, "false", "FAIL", name])
      end
      expect(lines(run_task, "guards").sole).to include("gate_guards" => "PASS")
    end

    it "names the reviewer's five and the accepted-transfer guard, and fails a guard replica mode would skip" do
      %w[payouts_reversal_return_check payouts_reversal_return_check_on_insert payout_return_proofs_check
        payout_return_proofs_commit payouts_settlement_guard payouts_accepted_transfer_guard].each do |name|
        table = FinancialIntegrity::PREFLIGHT_TRIGGERS.fetch(name).first
        expect(with_change("ALTER TABLE #{table} DISABLE TRIGGER #{name}")).to include(name => "false", "gate_guards" => "FAIL")
        expect(with_change("ALTER TABLE #{table} ENABLE REPLICA TRIGGER #{name}")).to include(name => "false", "gate_guards" => "FAIL")
      end
    end

    it "fails a trigger rebound to another function, or a required function in another schema only" do
      rebound = with_change(<<~SQL)
        CREATE FUNCTION hafapass_spec_noop() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NULL; END; $$;
        DROP TRIGGER payouts_reversal_return_check ON payouts;
        CREATE CONSTRAINT TRIGGER payouts_reversal_return_check AFTER UPDATE OF status ON payouts
          DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION hafapass_spec_noop();
      SQL
      expect(rebound).to include("payouts_reversal_return_check" => "false", "gate_guards" => "FAIL")
      moved = with_change(<<~SQL)
        CREATE SCHEMA hafapass_spec_elsewhere;
        ALTER FUNCTION hafapass_payout_return_verified(bigint) SET SCHEMA hafapass_spec_elsewhere;
      SQL
      expect(moved).to include("hafapass_payout_return_verified" => "false", "gate_guards" => "FAIL")
    end
  end

  # CodeRabbit 4703321693: the task reads one repeatable-read snapshot. Every
  # statement commits on its own here, as on production, and another session
  # classifies and commits a capture after the statement was computed.
  describe "snapshot", :non_transactional do
    self.use_transactional_tests = false

    def clean!
      raise "Isolated test database required" unless ActiveRecord::Base.connection_db_config.database.end_with?("_test")

      ActiveRecord::Base.connection.execute(<<~SQL)
        TRUNCATE TABLE audit_logs, audit_write_failures, organizations, users, organizer_profiles, events, site_settings,
          webhook_events, checkout_attempts
        RESTART IDENTITY CASCADE
      SQL
    end

    # The outer setup commits here too, so everything is removed afterwards.
    after { clean! }

    it "counts only what its own snapshot saw when a capture is classified mid-run" do
      record_card_sale!(event, ticket_type: ticket_type, quantity: 2)
      classified_capture(items: [[1200, 160, 0, 0]], event: event)
      interleaved = false
      allow(Settlements::Calculator).to receive(:call).and_wrap_original do |original, *args|
        result = original.call(*args)
        unless interleaved
          interleaved = true
          Thread.new do
            ActiveRecord::Base.connection_pool.with_connection { classified_capture(items: [[500, 0, 0, 0]], event: event) }
          end.join
        end
        result
      end

      output = run_task
      expect(interleaved).to be(true)
      expect(UnfulfilledCapture.joins(:order).where(orders: { event_id: event.id }).count).to eq(2)
      expect(lines(output, "snapshot").sole).to include("isolation" => "repeatable_read", "read_only" => "on")
      expect(lines(output, "event").sole).to include("classified_captures" => "1")
    end
  end
end
