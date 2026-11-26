# frozen_string_literal: true

require_relative "../../lib/financial_integrity"

# A2 R2-2 (docs/design/never-fulfilled-captures.md §8.6, §8.10.5). One frozen
# determination per payout of whether its finalized settlement version funded
# Stripe custody, written when the payout is recorded paid (or derived once
# for history by `payout_custody:derive`). BPT reads it; nothing recomputes it.
# Additive: a new table, its functions and triggers. No existing row, payout
# writer or payout authority changes.
class CreatePayoutCustodyDeterminations < ActiveRecord::Migration[8.1]
  def up
    create_table :payout_custody_determinations do |t|
      t.references :payout, null: false, foreign_key: true, index: { unique: true }
      # The funded settlement version. No foreign key, so recording a payout
      # paid takes no new row lock on the settlement (docs/LOCKING.md).
      t.bigint :settlement_id, null: false
      t.string :determination, null: false
      t.string :basis, null: false
      t.bigint :funded_order_item_ids, array: true, null: false, default: []
      t.bigint :qualifying_payment_ids, array: true, null: false, default: []
      t.boolean :conservative_inclusion, null: false
      t.jsonb :evidence, null: false, default: {}
      t.datetime :determined_at, null: false
    end
    add_index :payout_custody_determinations, :settlement_id
    add_check_constraint :payout_custody_determinations,
      "determination IN ('stripe_custody', 'non_custodial', 'ambiguous')", name: "payout_custody_determinations_determination_valid"
    add_check_constraint :payout_custody_determinations,
      "basis IN ('recorded_at_paid', 'derived_history')", name: "payout_custody_determinations_basis_valid"
    add_check_constraint :payout_custody_determinations,
      "jsonb_typeof(evidence) = 'object'", name: "payout_custody_determinations_evidence_object"
    safety_assured { execute FinancialIntegrity::CUSTODY_SQL }
  end

  def down
    drop_table :payout_custody_determinations
    safety_assured { execute "DROP FUNCTION IF EXISTS hafapass_stamp_custody_determination()" }
  end
end
