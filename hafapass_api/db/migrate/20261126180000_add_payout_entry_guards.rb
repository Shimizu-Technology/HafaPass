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
#   - a payout inserted already paid (or reversed, or paid then reversed in
#     the same transaction) commits only with its determination;
#   - the P4 platform-only proof needs positive funding lineage (every payout
#     that moved or may move money is on a version with the capture's $0
#     line), and its hold starts at a cutoff that never moves later while the
#     proof fails (anchored at the last fence pass on the event, or at the
#     over-return exception's own opening, where the database checks the
#     proof: reconciliation_exceptions.proof_checked_at, and hold_started_at
#     when it failed then); a reversed payout defeats the proof until its
#     verified return is recorded;
#   - a payout on such an event becomes reversed (by any writer, A1
#     included) only when the same transaction records its exact verified
#     return, and an accepted transfer only after finance recorded the
#     acceptance (payouts_reversal_return_check, checked at commit);
#   - payout_return_proofs: the durable, non-personal proof of an exact
#     verified return (amount that left, return time, digest of the bank's
#     return reference), which the P4 proof and the reversal fence read
#     instead of audit payloads that retention anonymizes; append-only, and
#     a payout's settlement version is fixed once its custody is determined;
#   - a transfer the provider accepted after a fence refused it carries
#     payouts.provider_accepted_at: on any event, by any writer, it stays
#     committed (never paid, failed, pending, released or deleted) until
#     finance recorded the acceptance and its exact return
#     (payouts_accepted_transfer_guard, A2 recheck 758485ae finding 1);
#   - settlements.finalized_reader / finalized_recorded_at stamped by the
#     database at finalization, and reader_digest (the statement without its
#     payout lines) written by this release's Finalizer; all set once.
# Additive: six nullable columns, one new table, functions and triggers, and the
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
    # When the database checked an over-return exception's P4 proof at its
    # insert (hafapass_exception_hold_start); NULL on rows opened earlier.
    add_column :reconciliation_exceptions, :proof_checked_at, :datetime
    # A2 recheck finding 1 (758485ae): the durable accepted-transfer marker
    # (the provider's paid time) and finance's acceptance record, both set
    # once and guarded by payouts_accepted_transfer_guard for every writer.
    add_column :payouts, :provider_accepted_at, :datetime
    add_column :payouts, :accepted_transfer_recorded_at, :datetime
    # No personal data: the reference is kept only as its SHA-256 digest.
    create_table :payout_return_proofs do |t|
      t.references :payout, null: false, foreign_key: true, index: { unique: true }
      t.string :kind, null: false
      t.bigint :returned_amount_cents, null: false
      t.datetime :returned_at, null: false
      t.datetime :sent_at, null: false
      t.string :return_reference_digest, null: false
      t.datetime :recorded_at, null: false
    end
    add_check_constraint :payout_return_proofs,
      "kind IN ('verified_return', 'accepted_transfer_return', 'attached_return')", name: "payout_return_proofs_kind_valid"
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
      %w[payouts_accepted_transfer_guard payouts_accepted_transfer_guard_on_insert
        payouts_accepted_transfer_guard_on_delete].each { |trigger| execute "DROP TRIGGER IF EXISTS #{trigger} ON payouts" }
      execute "DROP FUNCTION IF EXISTS hafapass_guard_accepted_transfer()"
      execute "DROP TRIGGER IF EXISTS payouts_settlement_guard ON payouts"
      execute "DROP TRIGGER IF EXISTS payouts_reversal_return_check ON payouts"
      execute "DROP TRIGGER IF EXISTS payouts_reversal_return_check_on_insert ON payouts"
      execute "DROP TRIGGER IF EXISTS payout_custody_determinations_commit ON payout_custody_determinations"
      execute "DROP TRIGGER IF EXISTS payout_custody_determinations_check ON payout_custody_determinations"
      execute "DROP TRIGGER IF EXISTS payouts_require_custody ON payouts"
      execute "DROP TRIGGER IF EXISTS payouts_require_custody_on_insert ON payouts"
      execute "DROP TRIGGER IF EXISTS settlements_finalization_stamp ON settlements"
      execute FinancialIntegrity::BOUNDARY_SQL
      execute FinancialIntegrity::OPERATIONAL_SQL
      execute FinancialIntegrity::A1_READER_REQUIRED_SQL
      # OPERATIONAL_SQL above restored the A2 operational P4 proof and hold
      # start; this release's final proof helpers go with the rest.
      %w[hafapass_overpaid_hold_start(bigint) hafapass_overpaid_proof_lost_at(bigint,timestamp)
        hafapass_payout_return_verified(bigint) hafapass_check_payout_reversal()
        hafapass_guard_payout_settlement()
        hafapass_overpaid_proof_anchor(bigint) hafapass_overpaid_proof_facts(bigint)
        hafapass_require_inserted_payout_custody()
        hafapass_check_custody_commit() hafapass_check_custody_determination() hafapass_require_payout_custody()
        hafapass_stamp_settlement_finalization() hafapass_settlement_restated_at(bigint)
        hafapass_event_has_classified_capture(bigint)].each do |function|
        execute "DROP FUNCTION IF EXISTS #{function}"
      end
    end
    drop_table :payout_return_proofs, if_exists: true
    safety_assured do
      %w[hafapass_check_payout_return_proof() hafapass_check_payout_return_proof_commit()
        hafapass_payout_amount_left(bigint)].each { |function| execute "DROP FUNCTION IF EXISTS #{function}" }
    end
    remove_column :payouts, :accepted_transfer_recorded_at, if_exists: true
    remove_column :payouts, :provider_accepted_at, if_exists: true
    remove_column :reconciliation_exceptions, :proof_checked_at
    remove_column :settlements, :reader_digest
    remove_column :settlements, :finalized_recorded_at
    remove_column :settlements, :finalized_reader
  end
end
