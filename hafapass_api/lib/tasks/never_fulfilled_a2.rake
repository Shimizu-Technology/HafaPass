# frozen_string_literal: true

# A2 release checks (docs/NEVER_FULFILLED_RELEASE.md "A2 release",
# design §8.10.11, §10.5). Read-only: everything runs in one READ ONLY
# transaction that is rolled back, so any accidental write fails. Home base
# runs it against production; agents run it only on task-owned databases.
# The transaction is REPEATABLE READ, so every line reads one snapshot.
#
# Output is one key=value line per fact, for saving and diffing:
#   guards     the A2 triggers, functions and the a2_payout_entry cutover;
#   undisposed counts that must be zero before payouts on affected events
#              resume (unclassified/unposted, overlap captures, receipts
#              without identity, postings pending correction, repayment
#              operations or refunds with an unknown result);
#   custody    paid payouts with no frozen determination (zero after the
#              authorized payout_custody:derive), and ambiguous ones;
#   event      each event with a classified capture: its latest finalized
#              version and reader, whether it needs finalizing again, the
#              current payable, reservations (pending, processing, held),
#              sent transfers (paid) and what remains;
#   payout     each pending, processing or held payout on those events: its
#              approved version, restatement time, whether it is current,
#              and the finance action the guards leave open.
namespace :never_fulfilled do
  desc "Read-only A2 payout-entry preflight and organizer payable audit"
  task a2_preflight: :environment do
    connection = ActiveRecord::Base.connection
    line = ->(section, **facts) { puts ["section=#{section}", *facts.map { |key, value| "#{key}=#{value}" }].join("\t") }
    # A guard passes only when its trigger is on the expected table in this
    # schema and fires for this session's replication role (CodeRabbit
    # 4703321691): a disabled trigger keeps its pg_trigger row. 'O' fires in
    # origin and local mode, 'R' in replica mode, 'A' always, 'D' never.
    trigger = lambda do |name, table|
      connection.select_value(<<~SQL)
        SELECT EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE t.tgname = #{connection.quote(name)} AND c.relname = #{connection.quote(table)}
            AND n.nspname = current_schema() AND NOT t.tgisinternal
            AND (t.tgenabled = 'A' OR (t.tgenabled = 'O' AND current_setting('session_replication_role') <> 'replica')
              OR (t.tgenabled = 'R' AND current_setting('session_replication_role') = 'replica')))
      SQL
    end
    function = ->(name) { connection.select_value("SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = #{connection.quote(name)})") }

    # One read-only, repeatable-read snapshot (CodeRabbit 4703321693): a
    # capture classified while the task runs can never be counted beside a
    # statement computed without it. Inside an already open transaction (a
    # test's fixture transaction) the task joins it and reports its level.
    snapshot = connection.transaction_open? ? {} : { isolation: :repeatable_read }
    connection.transaction(**snapshot) do
      connection.execute("SET TRANSACTION READ ONLY")
      line.call("snapshot", isolation: connection.select_value("SHOW transaction_isolation").tr(" ", "_"),
        read_only: connection.select_value("SHOW transaction_read_only"))
      guards = {
        payouts_repayment_fence: trigger.call("payouts_repayment_fence", "payouts"),
        payouts_require_custody: trigger.call("payouts_require_custody", "payouts"),
        payouts_require_custody_on_insert: trigger.call("payouts_require_custody_on_insert", "payouts"),
        audit_logs_payout_submission_fence: trigger.call("audit_logs_payout_submission_fence", "audit_logs"),
        settlements_finalization_fence: trigger.call("settlements_finalization_fence", "settlements"),
        settlements_finalization_stamp: trigger.call("settlements_finalization_stamp", "settlements"),
        payout_custody_determinations_check: trigger.call("payout_custody_determinations_check", "payout_custody_determinations"),
        payout_custody_determinations_commit: trigger.call("payout_custody_determinations_commit", "payout_custody_determinations"),
        hafapass_settlement_restated_at: function.call("hafapass_settlement_restated_at"),
        hafapass_overpaid_proof_facts: function.call("hafapass_overpaid_proof_facts"),
        reader_rule_current: connection.select_value("SELECT pg_get_functiondef('hafapass_settlement_reader_required(bigint)'::regprocedure) " \
          "LIKE #{connection.quote("%#{FinancialIntegrity::SETTLEMENT_READER}%")}")
      }
      cutover = FinancialCutover.recorded_at(FinancialIntegrity::PAYOUT_ENTRY_CUTOVER)
      line.call("guards", **guards, a2_payout_entry_cutover: cutover&.utc&.iso8601(6) || "missing",
        gate_guards: guards.values.all? && cutover ? "PASS" : "FAIL")

      report = Commerce::NeverFulfilledReconcile.call(dry_run: true)
      undisposed = {
        unclassified_or_unposted: report.assessments.count { |item| %w[held reconciled].exclude?(item.disposition) },
        unposted_movement_payments: Commerce::NeverFulfilledReconcile.unposted_movement_payment_ids.count,
        overlap_captures: Commerce::NeverFulfilledReconcile.overlap_capture_ids.count,
        orphan_receipts_without_identity: Commerce::NeverFulfilledReconcile.orphan_receipts_without_identity.count,
        postings_not_recognized: BuyerReturnPosting.where.not(recognition_state: "recognized").count,
        repayment_operations_unsettled: RepaymentOperation.where.not(state: %w[succeeded failed_terminal]).count,
        refunds_result_unknown_on_classified: Refund.where(failure_code: "provider_result_unknown",
          payment_id: UnfulfilledCapture.select(:payment_id)).count
      }
      line.call("undisposed", **undisposed, gate_zero_undisposed: undisposed.values.all?(&:zero?) ? "PASS" : "FAIL")
      line.call("holds", **ReconciliationException.open.where(code: FinancialIntegrity::PAYOUT_BLOCKING_CODES +
        [FinancialIntegrity::OVERPAID_CODE]).group(:code).count.sort.to_h,
        overpaid_proven: Commerce::NeverFulfilledPayoutHold.proven_platform_only_overpaid.count)

      paid = Payout.where(status: %i[paid reversed]).where.not(paid_at: nil)
      undetermined = PayoutCustody.undetermined(paid).count
      line.call("custody", undetermined_paid_payouts: undetermined,
        ambiguous: PayoutCustodyDetermination.where(determination: "ambiguous").count,
        gate_custody_complete: undetermined.zero? ? "PASS" : "FAIL (run payout_custody:derive with authority)")

      affected = Event.where(id: Order.where(id: UnfulfilledCapture.select(:order_id)).select(:event_id)).order(:id)
      affected.find_each do |event|
        calculation = Settlements::Calculator.call(event)
        latest = event.settlements.status_finalized.order(:version).last
        payouts = event.payouts.order(:id).to_a
        reserved = payouts.select { |payout| %w[pending processing held].include?(payout.status) }.sum(&:amount_cents)
        sent = payouts.select(&:status_paid?).sum(&:amount_cents)
        payable = calculation.attributes[:payable_cents]
        current_digest = PayoutEntryGuard.reader_digest(calculation.items)
        latest_current = latest && latest.finalized_reader == FinancialIntegrity::SETTLEMENT_READER &&
          latest.reader_digest == current_digest
        line.call("event", event_id: event.id, organization_id: event.organization_id,
          classified_captures: UnfulfilledCapture.where(order_id: event.orders.select(:id)).count,
          latest_version: latest&.version || "none", latest_reader: latest&.finalized_reader || "none",
          latest_restated_at: latest && PayoutEntryGuard.restated_at(latest)&.utc&.iso8601(6) || "none",
          needs_finalizing: latest_current ? "no" : "yes",
          current_payable_cents: payable, reserved_cents: reserved, sent_cents: sent,
          remaining_cents: payable - reserved - sent,
          over_committed: reserved + sent > payable ? "yes (keep held; finance reviews)" : "no",
          organization_available_cents: OrganizationPayoutBalance.available_cents(event.organization))
        payouts.select { |payout| %w[pending processing held].include?(payout.status) }.each do |payout|
          stale = PayoutEntryGuard.staleness(payout, items: calculation.items)
          restated_at = stale&.fetch(:restated_at)
          submissions = AuditLog.where(auditable: payout, action: "payout.submission_requested")
          submitted_before = restated_at ? submissions.where("occurred_at < ?", restated_at).exists? : submissions.exists?
          action = if stale.nil? then "current"
          elsif submitted_before then "record paid only with transfer evidence before #{restated_at&.utc&.iso8601(6) || 'the change'}; else fail and reissue"
          else "not sent: fail and reissue on a new version"
          end
          line.call("payout", event_id: event.id, payout_id: payout.id, status: payout.status,
            held_from: payout.held_from_status || "-", amount_cents: payout.amount_cents,
            settlement_version: payout.settlement.version, settlement_reader: payout.settlement.finalized_reader || "none",
            restated_at: restated_at&.utc&.iso8601(6) || "none", current: stale.nil?, submitted: submissions.exists?,
            action: action)
        end
      end
      raise ActiveRecord::Rollback
    end
  end
end
