class SnapshotPaymentContextAndCheckoutRecovery < ActiveRecord::Migration[8.0]
  def change
    add_column :payments, :provider_environment, :string
    add_column :payments, :provider_account_id, :string
    add_column :orders, :checkout_key_digest, :string
    add_column :orders, :checkout_request_digest, :string
    add_column :orders, :checkout_recovery_expires_at, :datetime
    add_index :orders, :checkout_key_digest, unique: true
    reversible do |direction|
      direction.up do
        execute "UPDATE payments SET provider_environment = 'simulate' WHERE provider = 'stripe' AND provider_payment_id LIKE 'sim_%'"
      end
    end
  end
end
