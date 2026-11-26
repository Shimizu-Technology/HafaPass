# frozen_string_literal: true

require_relative "../../lib/financial_integrity"

# A2 payout entry and overlap fences (docs/design/never-fulfilled-captures.md
# §8.10.11, M-09). The pre-deploy migration of the A2 release, so it is in
# place before any A2 process starts and while A1 processes still run:
#   - payouts and finalization on an event with a classified capture need
#     this release's settlement reader (A1 processes are refused there);
#   - a payout whose settlement version lacks a classified capture's $0 line
#     cannot be created, released or submitted, and is recorded paid only
#     for a transfer submitted and confirmed sent before the version was
#     restated (hafapass_settlement_restated_at);
#   - paid needs the payout's frozen custody determination in the same
#     transaction; historical determinations need the authorized derivation;
#   - settlements.finalized_reader / finalized_recorded_at stamped by the
#     database at finalization, and reader_digest (the statement without its
#     payout lines) written by this release's Finalizer; all set once.
# Additive: three nullable columns, functions and triggers, and the
# a2_payout_entry cutover row. No existing row changes. Non-affected events
# keep every A1 behaviour except that paid needs the custody row, which
# only this release writes (an A1 paid recording fails closed and is
# recorded again from A2).
class AddPayoutEntryGuards < ActiveRecord::Migration[8.1]
  def up
    add_column :settlements, :finalized_reader, :string
    add_column :settlements, :finalized_recorded_at, :datetime
    # This release's statement digest without payout lines (PayoutEntryGuard),
    # written by its Finalizer; NULL on versions an older reader finalized.
    add_column :settlements, :reader_digest, :string
    safety_assured do
      execute "INSERT INTO financial_cutovers (key) VALUES ('#{FinancialIntegrity::PAYOUT_ENTRY_CUTOVER}') ON CONFLICT (key) DO NOTHING"
      execute FinancialIntegrity::PAYOUT_ENTRY_SQL
    end
  end

  # Test and rehearsal only (never run down migrations in production, design
  # §10.5). Restores the A2 operational-reader fences and the A1 reader rule.
  # The cutover row is append-only and stays; a re-run keeps its first time.
  def down
    safety_assured do
      execute "DROP TRIGGER IF EXISTS payout_custody_determinations_commit ON payout_custody_determinations"
      execute "DROP TRIGGER IF EXISTS payout_custody_determinations_check ON payout_custody_determinations"
      execute "DROP TRIGGER IF EXISTS payouts_require_custody ON payouts"
      execute "DROP TRIGGER IF EXISTS settlements_finalization_stamp ON settlements"
      execute FinancialIntegrity::BOUNDARY_SQL
      execute FinancialIntegrity::OPERATIONAL_SQL
      execute FinancialIntegrity::A1_READER_REQUIRED_SQL
      %w[hafapass_check_custody_commit() hafapass_check_custody_determination() hafapass_require_payout_custody()
        hafapass_stamp_settlement_finalization() hafapass_settlement_restated_at(bigint)
        hafapass_event_has_classified_capture(bigint)].each do |function|
        execute "DROP FUNCTION IF EXISTS #{function}"
      end
    end
    remove_column :settlements, :reader_digest
    remove_column :settlements, :finalized_recorded_at
    remove_column :settlements, :finalized_reader
  end
end
