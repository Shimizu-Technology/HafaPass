class FreezeMessageTransportContext < ActiveRecord::Migration[8.0]
  def change
    add_column :message_deliveries, :transport_context_digest, :string
    create_table :checkout_attempts do |t|
      t.string :checkout_key_digest, null: false, limit: 64
      t.string :request_digest, null: false, limit: 64
      t.integer :status, null: false, default: 0
      t.string :lease_token_digest, limit: 64
      t.datetime :lease_expires_at
      t.references :order, foreign_key: true, index: { unique: true }
      t.timestamps
    end
    add_index :checkout_attempts, :checkout_key_digest, unique: true
    add_check_constraint :checkout_attempts,
      "(status = 0 AND order_id IS NULL AND lease_token_digest IS NOT NULL AND lease_expires_at IS NOT NULL) OR " \
      "(status = 1 AND order_id IS NULL AND lease_token_digest IS NULL AND lease_expires_at IS NULL) OR " \
      "(status = 2 AND order_id IS NOT NULL AND lease_token_digest IS NULL AND lease_expires_at IS NULL)",
      name: "checkout_attempt_state"
  end
end
