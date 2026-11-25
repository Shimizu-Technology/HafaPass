# frozen_string_literal: true

require_relative "../../lib/financial_integrity"

# One append-only row per captured payment HåfaPass did not fulfil, plus the
# database guards of docs/design/never-fulfilled-captures.md §4.2. Nothing in
# this release writes a classification; the guards only reject things the
# running code never does legitimately.
class CreateNeverFulfilledCaptures < ActiveRecord::Migration[8.1]
  CODES = %w[
    late_payment_success_after_inventory_release
    late_payment_success_after_hold_expiry
    pass_all_included_nights_cancelled
    unfulfilled_second_capture
    event_not_eligible
  ].freeze

  def up
    create_table :never_fulfilled_captures do |t|
      t.references :order, null: false, foreign_key: true, index: true
      t.bigint :payment_id, null: false
      t.string :capture_scope, null: false
      t.string :code, null: false
      t.integer :captured_cents, null: false
      t.string :currency, null: false
      t.integer :proceeds_cents, null: false
      t.integer :fee_cents, null: false
      t.integer :organizer_fee_cents, null: false
      t.integer :tax_cents, null: false
      t.datetime :capture_recorded_at, null: false
      t.string :processing_bearer, null: false
      t.string :dispute_fee_bearer, null: false
      t.string :allocation_policy, null: false
      t.string :policy_version, null: false
      t.string :provenance, null: false
      t.jsonb :provenance_evidence, null: false, default: {}
      t.datetime :created_at, null: false, default: -> { FinancialIntegrity::NOW_UTC }

      t.index :payment_id, unique: true
      t.check_constraint "capture_scope IN ('order', 'payment')", name: "never_fulfilled_captures_scope_valid"
      t.check_constraint "code IN (#{CODES.map { |code| "'#{code}'" }.join(', ')})", name: "never_fulfilled_captures_code_valid"
      t.check_constraint "captured_cents > 0", name: "never_fulfilled_captures_captured_positive"
      t.check_constraint "char_length(currency) = 3", name: "never_fulfilled_captures_currency_length"
      t.check_constraint "proceeds_cents >= 0 AND fee_cents >= 0 AND organizer_fee_cents >= 0 AND tax_cents >= 0",
        name: "never_fulfilled_captures_components_nonnegative"
      t.check_constraint "proceeds_cents + fee_cents + organizer_fee_cents + tax_cents = captured_cents",
        name: "never_fulfilled_captures_components_sum"
      t.check_constraint "capture_scope = 'order' OR (fee_cents = 0 AND organizer_fee_cents = 0 AND tax_cents = 0)",
        name: "never_fulfilled_captures_payment_scope_principal"
      t.check_constraint "processing_bearer IN ('platform', 'organizer') AND dispute_fee_bearer IN ('platform', 'organizer')",
        name: "never_fulfilled_captures_bearers_valid"
      t.check_constraint "allocation_policy IN ('item_record', 'cumulative_pro_rata')",
        name: "never_fulfilled_captures_allocation_policy_valid"
      t.check_constraint "provenance IN ('lifecycle', 'backfill')", name: "never_fulfilled_captures_provenance_valid"
      t.check_constraint "provenance = 'lifecycle' OR provenance_evidence <> '{}'::jsonb",
        name: "never_fulfilled_captures_backfill_evidence"
      t.foreign_key :payments, column: [:payment_id, :order_id], primary_key: [:id, :order_id],
        name: "fk_never_fulfilled_captures_same_order_payment"
    end

    create_table :financial_cutovers do |t|
      t.string :key, null: false
      t.datetime :recorded_at, null: false, default: -> { FinancialIntegrity::NOW_UTC }
      t.index :key, unique: true
    end

    # CREATE TRIGGER holds SHARE ROW EXCLUSIVE on payments until this
    # transaction commits, so every capture left with a NULL
    # capture_recorded_at was recorded before the cutover row's time.
    safety_assured do
      execute FinancialIntegrity::FOUNDATION_SQL
      execute "INSERT INTO financial_cutovers (key) VALUES ('a1_capture_recording')"
    end
  end

  def down
    safety_assured do
      execute <<~SQL
        DROP TRIGGER IF EXISTS tickets_issuance_guard ON tickets;
        DROP TRIGGER IF EXISTS orders_fulfillment_guard ON orders;
        DROP TRIGGER IF EXISTS payments_capture_recorded_at ON payments;
        DROP FUNCTION IF EXISTS hafapass_guard_ticket_issuance();
        DROP FUNCTION IF EXISTS hafapass_guard_order_fulfillment();
        DROP FUNCTION IF EXISTS hafapass_payment_capture_recorded_at();
      SQL
      drop_table :financial_cutovers
      drop_table :never_fulfilled_captures
      execute <<~SQL
        DROP FUNCTION IF EXISTS hafapass_check_never_fulfilled_capture();
        DROP FUNCTION IF EXISTS hafapass_mark_never_fulfilled_order();
        DROP FUNCTION IF EXISTS hafapass_append_only();
        DROP FUNCTION IF EXISTS hafapass_append_only_truncate();
      SQL
    end
  end
end
