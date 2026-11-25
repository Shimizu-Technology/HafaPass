# frozen_string_literal: true

require_relative "../../lib/financial_integrity"

# Repayment operations for never-fulfilled captures and the A1-R1
# compatibility fence (docs/design/never-fulfilled-captures.md §6.3, §10.1,
# A1 tranche 4). Additive. The running release (7bcd97c2) never writes these
# tables or columns. The fence rejects only an outbound reservation or a last
# local gate for a fenced payment, and payout creation, release or submission
# on an event with an open never-fulfilled item: things old code must not do
# once A1 knows the money belongs to the buyer. It runs as a pre-deploy
# migration, so it is in place before any R1 process starts.
class CreateRepaymentOperations < ActiveRecord::Migration[8.1]
  STATES = %w[reserved submitting unknown succeeded failed_terminal].freeze
  SOURCES = %w[automatic admin_late_capture admin_order_refund fraud_warning evaluator queue_retry adoption].freeze

  def up
    create_table :repayment_operations do |t|
      t.references :never_fulfilled_capture, null: false, foreign_key: true, index: false
      t.references :payment, null: false, foreign_key: true, index: false
      t.integer :sequence, null: false
      t.integer :amount_cents, null: false
      t.string :currency, null: false
      t.string :idempotency_key, null: false
      t.string :state, null: false, default: "reserved"
      t.string :source, null: false
      t.boolean :adopted, null: false, default: false
      t.references :refund, foreign_key: true, index: { unique: true }
      t.integer :submission_count, null: false, default: 0
      t.datetime :last_submitted_at
      t.string :terminal_reason
      t.jsonb :evidence, null: false, default: {}
      t.datetime :created_at, null: false, default: -> { FinancialIntegrity::NOW_UTC }
      t.datetime :updated_at, null: false

      t.index [:never_fulfilled_capture_id, :sequence], unique: true, name: "index_repayment_operations_on_capture_sequence"
      t.index :idempotency_key, unique: true
      t.index [:payment_id, :state]
      t.check_constraint "state IN (#{STATES.map { |state| "'#{state}'" }.join(', ')})", name: "repayment_operations_state_valid"
      t.check_constraint "source IN (#{SOURCES.map { |source| "'#{source}'" }.join(', ')})", name: "repayment_operations_source_valid"
      t.check_constraint "amount_cents > 0", name: "repayment_operations_amount_positive"
      t.check_constraint "sequence > 0", name: "repayment_operations_sequence_positive"
      t.check_constraint "submission_count >= 0", name: "repayment_operations_submission_count_nonnegative"
      t.check_constraint "state NOT IN ('submitting', 'unknown') OR refund_id IS NOT NULL",
        name: "repayment_operations_submitted_has_refund"
    end

    add_column :refunds, :repayment_operation_id, :bigint
    add_foreign_key :refunds, :repayment_operations, column: :repayment_operation_id, validate: false
    add_column :webhook_events, :replayed_at, :datetime

    # CREATE TRIGGER takes SHARE ROW EXCLUSIVE on refunds and payouts until
    # commit, so no old reservation, gate or payout change can interleave
    # with installing the fence.
    safety_assured do
      execute FinancialIntegrity::REPAYMENT_SQL
      execute "INSERT INTO financial_cutovers (key) VALUES ('a1_repayment_fence') ON CONFLICT (key) DO NOTHING"
    end
  end

  def down
    safety_assured do
      execute <<~SQL
        DROP TRIGGER IF EXISTS refunds_repayment_fence ON refunds;
        DROP TRIGGER IF EXISTS payouts_repayment_fence ON payouts;
        DROP FUNCTION IF EXISTS hafapass_refund_repayment_fence();
        DROP FUNCTION IF EXISTS hafapass_payout_repayment_fence();
      SQL
      remove_column :webhook_events, :replayed_at
      remove_foreign_key :refunds, column: :repayment_operation_id
      remove_column :refunds, :repayment_operation_id
      drop_table :repayment_operations
      execute <<~SQL
        DROP FUNCTION IF EXISTS hafapass_check_repayment_operation();
        DROP FUNCTION IF EXISTS hafapass_fenced_payment(bigint);
      SQL
    end
  end
end
