class RememberPayoutHoldStatus < ActiveRecord::Migration[8.0]
  def up
    add_column :payouts, :held_from_status, :string
    execute <<~SQL
      UPDATE payouts SET held_from_status = (
        SELECT before_data->>'status' FROM audit_logs
        WHERE auditable_type = 'Payout' AND auditable_id = payouts.id
          AND action = 'payout.held_for_cancellation'
        ORDER BY id DESC LIMIT 1
      ) WHERE status = 5
    SQL
  end

  def down
    remove_column :payouts, :held_from_status
  end
end
