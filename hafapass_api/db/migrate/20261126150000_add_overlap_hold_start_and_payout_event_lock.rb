# frozen_string_literal: true

require_relative "../../lib/financial_integrity"

# A1-R1 boundary fixes (docs/design/never-fulfilled-captures.md §6.9).
# Additive: one nullable column, functions and triggers. Runs as a pre-deploy
# migration, so the guards exist before any R1 process starts and stay
# through a rollback to 7bcd97c2. For every writer:
#
#   - a capture an older release acknowledged on an order already marked
#     never fulfilled holds the event's payouts and statements until it is
#     classified or quarantined, whatever the order's status since;
#   - a blocking exception written while its payment is an unclassified
#     overlap capture keeps that capture's hold start
#     (reconciliation_exceptions.hold_started_at, stamped by the database,
#     never changed), so classification or quarantine never moves the payout
#     cutoff later;
#   - every payout fence decision first holds the event row that each capture
#     holds until it commits, NOWAIT, so it never waits in reverse lock order
#     and reads a snapshot that includes any capture committed first.
class AddOverlapHoldStartAndPayoutEventLock < ActiveRecord::Migration[8.1]
  def up
    add_column :reconciliation_exceptions, :hold_started_at, :datetime
    safety_assured do
      execute FinancialIntegrity::BOUNDARY_SQL
      execute "INSERT INTO financial_cutovers (key) VALUES ('a1_boundary_guards') ON CONFLICT (key) DO NOTHING"
    end
  end

  def down
    safety_assured do
      execute <<~SQL
        DROP TRIGGER IF EXISTS reconciliation_exceptions_hold_start ON reconciliation_exceptions;
        DROP FUNCTION IF EXISTS hafapass_exception_hold_start();
      SQL
      # The capture predicate, block start and payout fence keep working with
      # their 20261126140000 definitions; the submission and finalization
      # fences with their 20261126130000 ones.
      overlap = FinancialIntegrity::OVERLAP_SQL
      [["CREATE OR REPLACE FUNCTION hafapass_unclassified_capture", "CREATE OR REPLACE FUNCTION hafapass_payout_block_start"],
        ["CREATE OR REPLACE FUNCTION hafapass_payout_block_start", "-- P10 strict for every payout writer"],
        ["CREATE OR REPLACE FUNCTION hafapass_payout_repayment_fence()", "DROP TRIGGER IF EXISTS payouts_repayment_fence"]]
        .each { |start, stop| execute overlap[overlap.index(start)...overlap.index(stop)] }
      evidence = FinancialIntegrity::EVIDENCE_SQL
      [["CREATE OR REPLACE FUNCTION hafapass_payout_submission_fence()", "DROP TRIGGER IF EXISTS audit_logs_payout_submission_fence"],
        ["CREATE OR REPLACE FUNCTION hafapass_settlement_finalization_fence()", "DROP TRIGGER IF EXISTS settlements_finalization_fence"]]
        .each { |start, stop| execute evidence[evidence.index(start)...evidence.index(stop)] }
      execute <<~SQL
        DROP FUNCTION IF EXISTS hafapass_lock_payout_event(bigint);
        DROP FUNCTION IF EXISTS hafapass_overlap_hold_start(bigint);
      SQL
    end
    remove_column :reconciliation_exceptions, :hold_started_at
  end
end
