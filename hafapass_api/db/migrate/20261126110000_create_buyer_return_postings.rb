# frozen_string_literal: true

require_relative "../../lib/financial_integrity"

# Durable gross return postings for never-fulfilled captures
# (docs/design/never-fulfilled-captures.md §5, A1 tranche 3), and the
# database-stamped recording times they are recognized by. Additive: the
# running release never writes these columns or this table, and the new
# triggers only stamp times or reject things it never does legitimately.
class CreateBuyerReturnPostings < ActiveRecord::Migration[8.1]
  KINDS = %w[refund dispute_loss dispute_loss_reversal refund_reversal].freeze

  def up
    add_column :refunds, :success_recorded_at, :datetime
    add_column :disputes, :loss_recorded_at, :datetime
    add_column :disputes, :loss_reversed_at, :datetime

    create_table :buyer_return_postings do |t|
      t.references :never_fulfilled_capture, null: false, foreign_key: true, index: false
      t.integer :sequence, null: false
      t.string :kind, null: false
      t.string :source_type, null: false
      t.bigint :source_id, null: false
      t.references :reverses_posting, foreign_key: { to_table: :buyer_return_postings }, index: { unique: true }
      t.integer :gross_cents, null: false
      t.integer :applied_cents, null: false
      t.integer :excess_cents, null: false
      t.integer :proceeds_cents, null: false
      t.integer :fee_cents, null: false
      t.integer :organizer_fee_cents, null: false
      t.integer :tax_cents, null: false
      t.datetime :recorded_at, null: false
      t.string :recording_source, null: false
      t.datetime :capture_recorded_at, null: false
      t.datetime :recognized_at, null: false
      t.string :recognition_state, null: false, default: "recognized"
      t.string :allocation_policy, null: false
      t.string :policy_version, null: false
      t.string :allocation_method, null: false
      t.jsonb :evidence, null: false, default: {}
      t.text :note
      t.datetime :posted_at, null: false, default: -> { FinancialIntegrity::NOW_UTC }

      t.index [:never_fulfilled_capture_id, :sequence], unique: true, name: "index_buyer_return_postings_on_capture_sequence"
      t.index [:kind, :source_type, :source_id], unique: true, name: "index_buyer_return_postings_on_movement"
      t.index :recognized_at
      t.check_constraint "kind IN (#{KINDS.map { |kind| "'#{kind}'" }.join(', ')})", name: "buyer_return_postings_kind_valid"
      t.check_constraint "(kind IN ('refund', 'refund_reversal') AND source_type = 'Refund') OR " \
        "(kind IN ('dispute_loss', 'dispute_loss_reversal') AND source_type = 'Dispute')",
        name: "buyer_return_postings_source_matches_kind"
      t.check_constraint "applied_cents + excess_cents = gross_cents", name: "buyer_return_postings_gross_identity"
      t.check_constraint "proceeds_cents + fee_cents + organizer_fee_cents + tax_cents = applied_cents",
        name: "buyer_return_postings_components_sum"
      t.check_constraint "(kind IN ('refund', 'dispute_loss') AND reverses_posting_id IS NULL AND gross_cents > 0 " \
        "AND applied_cents >= 0 AND excess_cents >= 0 AND proceeds_cents >= 0 AND fee_cents >= 0 " \
        "AND organizer_fee_cents >= 0 AND tax_cents >= 0) OR " \
        "(kind IN ('dispute_loss_reversal', 'refund_reversal') AND reverses_posting_id IS NOT NULL AND gross_cents < 0)",
        name: "buyer_return_postings_direction"
      t.check_constraint "recognized_at = GREATEST(recorded_at, capture_recorded_at)",
        name: "buyer_return_postings_recognition"
      t.check_constraint "recognition_state IN ('recognized', 'pending_correction')",
        name: "buyer_return_postings_recognition_state_valid"
      t.check_constraint "recording_source IN ('database', 'backfill')", name: "buyer_return_postings_recording_source_valid"
      t.check_constraint "recording_source = 'database' OR evidence <> '{}'::jsonb",
        name: "buyer_return_postings_backfill_evidence"
      t.check_constraint "allocation_method IN ('refund_items', 'bounded', 'cumulative_pro_rata', 'recomputed')",
        name: "buyer_return_postings_allocation_method_valid"
      t.check_constraint "sequence > 0", name: "buyer_return_postings_sequence_positive"
    end

    # CREATE TRIGGER holds SHARE ROW EXCLUSIVE on refunds and disputes until
    # this transaction commits, so every succeeded refund or lost dispute left
    # with a NULL recording time was recorded before the cutover row's time.
    # Cutovers are append-only: after a local down/up the first time stands,
    # which only narrows what a backfill may accept.
    safety_assured do
      execute FinancialIntegrity::RETURNS_SQL
      execute "INSERT INTO financial_cutovers (key) VALUES ('a1_return_recording') ON CONFLICT (key) DO NOTHING"
    end
  end

  def down
    safety_assured do
      execute <<~SQL
        DROP TRIGGER IF EXISTS refunds_success_recorded_at ON refunds;
        DROP TRIGGER IF EXISTS disputes_recorded_at ON disputes;
        DROP FUNCTION IF EXISTS hafapass_refund_success_recorded_at();
        DROP FUNCTION IF EXISTS hafapass_dispute_recorded_at();
      SQL
      drop_table :buyer_return_postings
      execute "DROP FUNCTION IF EXISTS hafapass_check_buyer_return_posting()"
      remove_column :disputes, :loss_reversed_at
      remove_column :disputes, :loss_recorded_at
      remove_column :refunds, :success_recorded_at
    end
  end
end
