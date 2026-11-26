# frozen_string_literal: true

# A2 release checks (docs/NEVER_FULFILLED_RELEASE.md "A2 release",
# design §8.10.11, §10.5). Read-only: everything runs in one READ ONLY
# transaction that is rolled back, so any accidental write fails. Home base
# runs it against production; agents run it only on task-owned databases.
# The transaction is REPEATABLE READ, so every line reads one snapshot.
#
# Output is one key=value line per fact, for saving and diffing:
#   guards     every required money trigger (enabled, on its table, running
#              its function, in this schema), functions, the a2_payout_entry
#              cutover, and the names of any failing guard;
#   undisposed counts that must be zero before payouts on affected events
#              resume (unclassified/unposted, overlap captures, receipts
#              without identity, postings pending correction, repayment
#              operations or refunds with an unknown result);
#   accepted   transfers the provider accepted after a fence refused them
#              (durable marker, finance's acknowledgement, observed-only
#              times) and any acceptance shown only by its audit (gate: 0);
#   custody    paid payouts with no frozen determination (zero after the
#              authorized payout_custody:derive), and ambiguous ones;
#   event      each event with a classified capture: its latest finalized
#              version and reader, whether it needs finalizing again, the
#              current payable, reservations (pending, processing, held),
#              sent transfers (paid) and what remains;
#   payout     each pending, processing or held payout on those events: its
#              approved version, restatement time, whether it is current,
#              its provider acceptance (none, audit_only, marked,
#              acknowledged), whether finance must escalate (yes, if_sent,
#              if_sent_after, no) and the finance action the guards leave
#              open. A payout submitted only after the change is never
#              reported unsent: the bank is checked first.
#
# The runbook runs it before the migration too (A2 recheck finding 3,
# 8132fe22), on the A1 schema. The schema line says which schema it read
# (state=a2, or state=pre_a2 with the missing A2 columns, table and
# functions). On pre_a2 it never names an absent column or function: the
# guard gate FAILs as expected, the undisposed and evidence-only gates run
# on A1's own tables, the custody gate FAILs (no custody table before the
# migration) and every value that only the A2 reader or its functions can
# compute (P4 proof, payable, remaining, restatement time, the organization's
# available balance) prints after_migration. Every payout on an affected
# event is then on a version an older reader finalized, so none is current.
namespace :never_fulfilled do
  desc "Read-only A2 payout-entry preflight and organizer payable audit"
  task a2_preflight: :environment do
    connection = ActiveRecord::Base.connection
    line = ->(section, **facts) { puts ["section=#{section}", *facts.map { |key, value| "#{key}=#{value}" }].join("\t") }
    # A guard passes only when its trigger is on the expected table in this
    # schema and fires for this session's replication role (CodeRabbit
    # 4703321691): a disabled trigger keeps its pg_trigger row. 'O' fires in
    # origin and local mode, 'R' in replica mode, 'A' always, 'D' never. A2
    # recheck finding 2 (758485ae): every required money guard
    # (FinancialIntegrity::PREFLIGHT_TRIGGERS: the reversal checks, the
    # return proof's insert and commit checks, frozen settlement ownership,
    # the accepted-transfer guard and every earlier fence) is checked, and
    # each must also run its own function from this schema.
    enabled_triggers = lambda do
      connection.select_rows(<<~SQL).to_set { |name, table, function| [name, table, function] }
        SELECT t.tgname, c.relname, p.proname FROM pg_trigger t
          JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
          JOIN pg_proc p ON p.oid = t.tgfoid JOIN pg_namespace pn ON pn.oid = p.pronamespace
          WHERE n.nspname = current_schema() AND pn.nspname = current_schema() AND NOT t.tgisinternal
            AND (t.tgenabled = 'A' OR (t.tgenabled = 'O' AND current_setting('session_replication_role') <> 'replica')
              OR (t.tgenabled = 'R' AND current_setting('session_replication_role') = 'replica'))
      SQL
    end
    function = lambda do |name|
      connection.select_value("SELECT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace " \
        "WHERE p.proname = #{connection.quote(name)} AND n.nspname = current_schema())")
    end

    # One read-only, repeatable-read snapshot (CodeRabbit 4703321693): a
    # capture classified while the task runs can never be counted beside a
    # statement computed without it. Inside an already open transaction (a
    # test's fixture transaction) the task joins it and reports its level.
    # The A2 schema this task reads beyond A1's, from the catalog (never
    # from the model's cached columns). Absent before the migration.
    column = lambda do |table, name|
      connection.select_value("SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = current_schema() " \
        "AND table_name = #{connection.quote(table)} AND column_name = #{connection.quote(name)})")
    end
    table = lambda do |name|
      connection.select_value("SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = current_schema() " \
        "AND table_name = #{connection.quote(name)})")
    end
    later = "after_migration"

    snapshot = connection.transaction_open? ? {} : { isolation: :repeatable_read }
    connection.transaction(**snapshot) do
      connection.execute("SET TRANSACTION READ ONLY")
      line.call("snapshot", isolation: connection.select_value("SHOW transaction_isolation").tr(" ", "_"),
        read_only: connection.select_value("SHOW transaction_read_only"))
      required = {
        "payouts.provider_accepted_at" => -> { column.call("payouts", "provider_accepted_at") },
        "payouts.provider_accepted_basis" => -> { column.call("payouts", "provider_accepted_basis") },
        "payouts.accepted_transfer_recorded_at" => -> { column.call("payouts", "accepted_transfer_recorded_at") },
        "settlements.finalized_reader" => -> { column.call("settlements", "finalized_reader") },
        "settlements.reader_digest" => -> { column.call("settlements", "reader_digest") },
        "stripe_fee_evidences.facts_recorded_at" => -> { column.call("stripe_fee_evidences", "facts_recorded_at") },
        "payout_custody_determinations" => -> { table.call("payout_custody_determinations") },
        "payout_return_proofs" => -> { table.call("payout_return_proofs") },
        **%w[hafapass_overpaid_platform_only hafapass_payout_block_start hafapass_settlement_restated_at
          hafapass_event_has_classified_capture].to_h { |name| ["#{name}()", -> { function.call(name) }] }
      }
      missing = required.reject { |_name, present| present.call }.keys
      a2 = missing.empty?
      line.call("schema", state: a2 ? "a2" : "pre_a2", missing: a2 ? "none" : missing.join(","))
      enabled = enabled_triggers.call
      guards = FinancialIntegrity::PREFLIGHT_TRIGGERS.to_h do |name, (table, trigger_function)|
        [name.to_sym, enabled.include?([name, table, trigger_function])]
      end
      FinancialIntegrity::PREFLIGHT_FUNCTIONS.each { |name| guards[name.to_sym] = function.call(name) }
      guards[:reader_rule_current] = function.call("hafapass_settlement_reader_required") && connection.select_value(
        "SELECT pg_get_functiondef('hafapass_settlement_reader_required(bigint)'::regprocedure) " \
        "LIKE #{connection.quote("%#{FinancialIntegrity::SETTLEMENT_READER}%")}")
      cutover = FinancialCutover.recorded_at(FinancialIntegrity::PAYOUT_ENTRY_CUTOVER)
      failing = guards.reject { |_name, ok| ok }.keys
      line.call("guards", **guards, a2_payout_entry_cutover: cutover&.utc&.iso8601(6) || "missing",
        required_guards: guards.size, failing_guards: failing.empty? ? "none" : failing.join(","),
        gate_guards: failing.empty? && cutover ? "PASS" : "FAIL")

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
        overpaid_proven: a2 ? Commerce::NeverFulfilledPayoutHold.proven_platform_only_overpaid.count : later)

      # Accepted transfers (CodeRabbit 4706251688): every acceptance carries
      # its durable marker. One shown only by its conflict audit has no time
      # to compare a return with; the reconciler records no outcome for it,
      # so the gate needs none (finance escalates any it names).
      refused_audits = AuditLog.where(auditable_type: "Payout", action: "payout.provider_result_conflict")
        .where("metadata->>'conflict_reason' = ?", FinancialIntegrity::PAYOUT_PAID_REFUSED_REASON)
      # CodeRabbit 4707205566: each A2 payout column is probed on its own,
      # not through the full schema gate, so a partially applied schema
      # (the marker column present, another A2 object missing) still counts
      # a marked payout as marked. Without the marker column (before the
      # migration) every such audit is evidence-only.
      marker_column = column.call("payouts", "provider_accepted_at")
      acknowledged_column = column.call("payouts", "accepted_transfer_recorded_at")
      basis_column = column.call("payouts", "provider_accepted_basis")
      audited_ids = Payout.where(id: refused_audits.select(:auditable_id)).order(:id).pluck(:id).to_set
      marked_ids = marker_column ? Payout.where("payouts.provider_accepted_at IS NOT NULL").pluck(:id).to_set : Set.new
      acknowledged_ids = marker_column && acknowledged_column ?
        Payout.where("payouts.provider_accepted_at IS NOT NULL AND payouts.accepted_transfer_recorded_at IS NOT NULL").pluck(:id).to_set : Set.new
      evidence_only = (audited_ids - marked_ids).sort
      line.call("accepted", marked: marked_ids.size,
        acknowledged: acknowledged_column ? acknowledged_ids.size : later,
        locally_observed: marker_column && basis_column ?
          Payout.where("payouts.provider_accepted_at IS NOT NULL AND payouts.provider_accepted_basis = 'locally_observed'").count : later,
        evidence_only: evidence_only.size, evidence_only_payout_ids: evidence_only.empty? ? "none" : evidence_only.join(","),
        gate_evidence_only_zero: evidence_only.empty? ? "PASS" : "FAIL (escalate each to finance)")

      # The finance action for an in-flight payout on an affected event.
      # CodeRabbit 4707205572: an accepted transfer is checked first; the
      # version rules below apply only to payouts the provider never
      # accepted. CodeRabbit 4707205586: a payout whose only submissions
      # are after the change may still have left (a manual transfer finance
      # sends later), so it is never reported unsent; the prior-send
      # exception is unavailable and finance checks the bank first. Only a
      # payout never submitted at all is reported unsent.
      acceptance_of = lambda do |payout|
        if acknowledged_ids.include?(payout.id) then "acknowledged"
        elsif marked_ids.include?(payout.id) then "marked"
        elsif audited_ids.include?(payout.id) then "audit_only"
        else "none"
        end
      end
      cutoff_label = ->(time) { time ? time.utc.iso8601(6) : "the change" }
      payout_action = lambda do |payout, acceptance:, blocked:, submitted:, submitted_before:, cutoff:, undated: false, confirmations: []|
        case acceptance
        when "audit_only"
          ["accepted (audit trail only): do not send, fail, reverse or reissue; it stays committed; escalate to finance " \
            "for an approved disposition", "yes"]
        when "marked"
          ["accepted transfer: it left; do not send, fail or reissue; record accepted_transfer, then reverse only with " \
            "the bank's exact return", "no"]
        when "acknowledged"
          ["accepted transfer (recorded): it stays committed; reverse only with the bank's exact return", "no"]
        else
          if !blocked then ["current", "no"]
          elsif !submitted && (payout.status_pending? || payout.held_from_status == "pending")
            ["not sent: fail and reissue on a new version", "no"]
          elsif undated && cutoff.nil? && submitted
            ["statement changed at an unproven time: check the bank first; if it left, keep it committed and " \
              "record an audited finance disposition with #{confirmations.join(' and ')}; only if the bank confirms " \
              "it never left, fail and reissue", "if_sent"]
          elsif submitted_before
            disposition = undated ? " An undated statement change also requires an audited finance disposition." : ""
            ["record paid only with transfer evidence before #{cutoff_label.call(cutoff)} and #{confirmations.join(' and ')}; " \
              "if the bank confirms it never left, fail and reissue; if it left at or after then, keep it committed and " \
              "escalate to finance.#{disposition}", "if_sent_after"]
          else
            ["submitted after #{cutoff_label.call(cutoff)} (or not on record): the prior-send exception is unavailable; " \
              "check the bank first; if it left, keep it committed and escalate to finance; only if the bank confirms it " \
              "never left, fail and reissue", "if_sent"]
          end
        end
      end

      if a2
        paid = Payout.where(status: %i[paid reversed]).where.not(paid_at: nil)
        undetermined = PayoutCustody.undetermined(paid).count
        line.call("custody", undetermined_paid_payouts: undetermined,
          ambiguous: PayoutCustodyDetermination.where(determination: "ambiguous").count,
          gate_custody_complete: undetermined.zero? ? "PASS" : "FAIL (run payout_custody:derive with authority)")
      else
        line.call("custody", undetermined_paid_payouts: later, ambiguous: later,
          gate_custody_complete: "FAIL (pre-migration: no custody table; payout_custody:derive runs after drain)")
      end

      affected = Event.where(id: Order.where(id: UnfulfilledCapture.select(:order_id)).select(:event_id)).order(:id)
      affected.find_each do |event|
        latest = event.settlements.status_finalized.order(:version).last
        payouts = event.payouts.order(:id).to_a
        reserved = payouts.select { |payout| %w[pending processing held].include?(payout.status) }.sum(&:amount_cents)
        sent = payouts.select(&:status_paid?).sum(&:amount_cents)
        common = { event_id: event.id, organization_id: event.organization_id,
          classified_captures: UnfulfilledCapture.where(order_id: event.orders.select(:id)).count,
          latest_version: latest&.version || "none" }
        in_flight = payouts.select { |payout| %w[pending processing held].include?(payout.status) }
        unless a2
          # Pre-migration: every version here was finalized by an older
          # reader, so the event needs finalizing again and no payout on it
          # is current. The A2 reader's figures come after the migration.
          line.call("event", **common, latest_reader: "pre_a2", latest_restated_at: later, needs_finalizing: "yes",
            current_payable_cents: later, reserved_cents: reserved, sent_cents: sent, remaining_cents: later,
            over_committed: later, organization_available_cents: later)
          in_flight.each do |payout|
            submitted = AuditLog.where(auditable: payout, action: "payout.submission_requested").exists?
            acceptance = acceptance_of.call(payout)
            # The restatement time is computed after the migration, so a
            # submission cannot be placed before or after it yet.
            action, escalate = if acceptance == "none" && submitted
              ["record paid only with transfer evidence before the restatement (its time after the migration); if the " \
                "bank confirms it never left, fail and reissue; if it left after the restatement, keep it committed and " \
                "escalate to finance", "if_sent_after"]
            else
              payout_action.call(payout, acceptance: acceptance, blocked: true, submitted: submitted, submitted_before: false,
                cutoff: nil)
            end
            line.call("payout", event_id: event.id, payout_id: payout.id, status: payout.status,
              held_from: payout.held_from_status || "-", amount_cents: payout.amount_cents,
              settlement_version: payout.settlement.version, settlement_reader: "pre_a2", restated_at: later,
              current: false, submitted: submitted, acceptance: acceptance, escalate: escalate, action: action)
          end
          next
        end
        calculation = Settlements::Calculator.call(event)
        payable = calculation.attributes[:payable_cents]
        current_digest = PayoutEntryGuard.reader_digest(calculation.items)
        latest_current = latest && latest.finalized_reader == FinancialIntegrity::SETTLEMENT_READER &&
          latest.reader_digest == current_digest
        line.call("event", **common, latest_reader: latest&.finalized_reader || "none",
          latest_restated_at: latest && PayoutEntryGuard.restated_at(latest)&.utc&.iso8601(6) || "none",
          needs_finalizing: latest_current ? "no" : "yes",
          current_payable_cents: payable, reserved_cents: reserved, sent_cents: sent,
          remaining_cents: payable - reserved - sent,
          over_committed: reserved + sent > payable ? "yes (keep held; finance reviews)" : "no",
          organization_available_cents: OrganizationPayoutBalance.available_cents(event.organization))
        in_flight.each do |payout|
          blockers = PayoutEntryGuard.blockers(payout, items: calculation.items, approvals: false,
            liability: { unresolved: false }).index_by { |blocker| blocker[:reason] }
          entry = blockers.dig("statement_changed", :entry)
          restated_at = entry&.fetch(:restated_at)
          statement_cutoff = entry&.fetch(:cutoff_at)
          hold_cutoff = blockers.dig("hold", :started_at)
          review_cutoff = blockers.dig("organizer_processing", :started_at)
          paid_cutoff_at = [statement_cutoff, hold_cutoff, review_cutoff].compact.min
          undated = entry && entry.fetch(:unproven).any?
          confirmations = []
          confirmations << "sent_before_hold_confirmed" if hold_cutoff || review_cutoff
          if entry && !(hold_cutoff && statement_cutoff && hold_cutoff <= statement_cutoff)
            confirmations << "sent_before_restatement_confirmed"
          end
          submissions = AuditLog.where(auditable: payout, action: "payout.submission_requested")
          submitted_before = paid_cutoff_at && submissions.where("occurred_at < ?", paid_cutoff_at).exists?
          acceptance = acceptance_of.call(payout)
          action, escalate = payout_action.call(payout, acceptance: acceptance, blocked: blockers.any?,
            submitted: submissions.exists?, submitted_before: submitted_before, cutoff: paid_cutoff_at, undated: undated,
            confirmations: confirmations)
          line.call("payout", event_id: event.id, payout_id: payout.id, status: payout.status,
            held_from: payout.held_from_status || "-", amount_cents: payout.amount_cents,
            settlement_version: payout.settlement.version, settlement_reader: payout.settlement.finalized_reader || "none",
            restated_at: restated_at&.utc&.iso8601(6) || "none", paid_cutoff_at: paid_cutoff_at&.utc&.iso8601(6) || "none",
            current: entry.nil?, submitted: submissions.exists?,
            acceptance: acceptance, escalate: escalate, action: action)
        end
      end
      raise ActiveRecord::Rollback
    end
  end
end
