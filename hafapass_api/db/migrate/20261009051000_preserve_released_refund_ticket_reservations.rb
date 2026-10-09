# frozen_string_literal: true

class PreserveReleasedRefundTicketReservations < ActiveRecord::Migration[8.1]
  def up
    add_column :refund_tickets, :released_at, :datetime
    execute <<~SQL
      UPDATE refund_tickets SET released_at = refunds.updated_at
      FROM refunds WHERE refund_tickets.refund_id = refunds.id AND refunds.status IN (2, 3)
    SQL
    remove_index :refund_tickets, :ticket_id
    add_index :refund_tickets, :ticket_id, unique: true, where: "released_at IS NULL"
  end

  def down
    if select_value("SELECT COUNT(*) FROM (SELECT ticket_id FROM refund_tickets GROUP BY ticket_id HAVING COUNT(*) > 1) duplicates").to_i.positive?
      raise ActiveRecord::IrreversibleMigration, "Cannot restore uniqueness without deleting historical refund attempts"
    end
    remove_index :refund_tickets, :ticket_id
    remove_column :refund_tickets, :released_at
    add_index :refund_tickets, :ticket_id, unique: true
  end
end
