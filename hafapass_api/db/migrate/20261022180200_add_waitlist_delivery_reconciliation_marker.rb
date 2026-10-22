class AddWaitlistDeliveryReconciliationMarker < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def change
    add_column :message_deliveries, :reconciled_at, :datetime
    add_index :message_deliveries, [:created_at, :id],
      where: "reconciled_at IS NULL AND template IN ('waitlist_notification', 'waitlist_offer') AND status IN (2, 3, 6, 7)",
      name: "idx_waitlist_deliveries_pending_reconciliation", algorithm: :concurrently
  end
end
