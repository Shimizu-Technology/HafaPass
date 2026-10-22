class CreateScheduledFeeChanges < ActiveRecord::Migration[8.1]
  def change
    add_column :site_settings, :fee_notice_days, :integer, null: false, default: 30

    create_table :fee_changes do |t|
      t.references :created_by, foreign_key: { to_table: :users }, null: false
      t.jsonb :old_terms, null: false
      t.jsonb :new_terms, null: false
      t.datetime :effective_at, null: false
      t.datetime :activated_at
      t.timestamps
    end
    add_index :fee_changes, :effective_at
    add_index :fee_changes, "(1)", unique: true, where: "activated_at IS NULL", name: "one_pending_fee_change"

    create_table :fee_change_notices do |t|
      t.references :fee_change, null: false, foreign_key: true
      t.references :organization, null: false, foreign_key: true
      t.references :owner, null: false, foreign_key: { to_table: :users }
      t.string :recipient_email, null: false
      t.integer :buyer_fee_percent, null: false
      t.string :fee_policy, null: false
      t.bigint :event_id, null: false
      t.datetime :acknowledged_at
      t.timestamps
    end
    add_foreign_key :fee_change_notices, :events
    add_index :fee_change_notices, [:fee_change_id, :organization_id, :owner_id], unique: true,
      name: "fee_change_notice_recipient_uniqueness"
  end
end
