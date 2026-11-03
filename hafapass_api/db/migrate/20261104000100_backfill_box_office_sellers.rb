class BackfillBoxOfficeSellers < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    validate_foreign_key :orders, :users, column: :sold_by_id
    safety_assured do
      execute <<~SQL
        WITH legacy AS MATERIALIZED (
          SELECT id, user_id FROM orders
          WHERE source = 'box_office' AND user_id IS NOT NULL
          FOR UPDATE
        ), cleared_tickets AS (
          UPDATE tickets SET holder_user_id = NULL
          FROM legacy
          WHERE tickets.order_id = legacy.id AND tickets.holder_user_id = legacy.user_id
          RETURNING tickets.id
        )
        UPDATE orders SET sold_by_id = COALESCE(orders.sold_by_id, legacy.user_id), user_id = NULL
        FROM legacy WHERE orders.id = legacy.id
      SQL
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
