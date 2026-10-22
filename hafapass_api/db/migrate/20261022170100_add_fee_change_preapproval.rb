class AddFeeChangePreapproval < ActiveRecord::Migration[8.1]
  def change
    add_reference :fee_changes, :preapproval, foreign_key: { to_table: :platform_capability_reviews }
    add_column :fee_changes, :preapproved_registry_digest, :string
    add_column :fee_changes, :blocked_at, :datetime
    add_column :fee_changes, :activation_error, :string
    add_index :fee_changes, :blocked_at
    remove_index :fee_changes, name: "one_pending_fee_change"
    add_index :fee_changes, "(1)", unique: true, where: "activated_at IS NULL AND blocked_at IS NULL",
      name: "one_pending_fee_change"
  end
end
