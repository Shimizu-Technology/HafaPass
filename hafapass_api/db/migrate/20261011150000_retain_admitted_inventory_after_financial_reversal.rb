# frozen_string_literal: true

class RetainAdmittedInventoryAfterFinancialReversal < ActiveRecord::Migration[8.0]
  def up
    add_column :tickets, :first_admitted_at, :datetime
    backfill_first_admission
    create_table :ticket_inventory_retentions do |t|
      t.references :ticket, null: false, foreign_key: true, index: { unique: true }
      t.references :refund, foreign_key: true
      t.references :dispute, foreign_key: true
      t.references :reconciliation_exception, null: false, foreign_key: true,
        index: { name: "index_ticket_retentions_on_reconciliation" }
      t.datetime :retained_at, null: false
    end
    add_check_constraint :ticket_inventory_retentions,
      "(refund_id IS NOT NULL AND dispute_id IS NULL) OR (refund_id IS NULL AND dispute_id IS NOT NULL)",
      name: "ticket_inventory_retentions_one_origin"
  end

  def down
    if select_value("SELECT COUNT(*) FROM ticket_inventory_retentions").to_i.positive?
      raise ActiveRecord::IrreversibleMigration, "Retained occupied inventory requires reconciliation; preserve its evidence"
    end
    drop_table :ticket_inventory_retentions
    remove_column :tickets, :first_admitted_at
  end

  def backfill_first_admission
    # Preserve the earliest existing server-side evidence, including an accepted
    # admission that was later reversed. Never fabricate an admission timestamp.
    execute <<~SQL
      UPDATE tickets SET first_admitted_at = checked_in_at
        WHERE checked_in_at IS NOT NULL AND first_admitted_at IS NULL;
      UPDATE tickets SET first_admitted_at = LEAST(tickets.first_admitted_at, admissions.first_received_at)
      FROM (SELECT ticket_id, MIN(received_at) AS first_received_at FROM admission_actions
        WHERE kind = 0 AND result = 0 AND ticket_id IS NOT NULL GROUP BY ticket_id) admissions
      WHERE tickets.id = admissions.ticket_id;
    SQL
  end
end
