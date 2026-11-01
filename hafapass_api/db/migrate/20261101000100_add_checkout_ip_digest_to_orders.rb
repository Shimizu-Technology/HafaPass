# frozen_string_literal: true

# Public checkout stores an HMAC of the buyer's IP address (never the address)
# so per-IP caps on held and free tickets can count an event's orders.
class AddCheckoutIpDigestToOrders < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = "index_orders_on_event_id_and_checkout_ip_digest"

  def up
    add_column :orders, :checkout_ip_digest, :string, if_not_exists: true
    existing = connection.indexes(:orders).find { |entry| entry.name == INDEX_NAME }
    return if existing&.valid?

    remove_index :orders, name: INDEX_NAME, algorithm: :concurrently if existing
    add_index :orders, [:event_id, :checkout_ip_digest], name: INDEX_NAME,
      where: "checkout_ip_digest IS NOT NULL", algorithm: :concurrently
  end

  def down
    remove_index :orders, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
    remove_column :orders, :checkout_ip_digest, if_exists: true
  end
end
