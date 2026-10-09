class IndexUnownedOrdersForGuestRecovery < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = "index_orders_on_normalized_guest_buyer_email"

  def up
    existing = connection.indexes(:orders).find { |index| index.name == INDEX_NAME }
    return if existing&.valid?

    remove_index :orders, name: INDEX_NAME, algorithm: :concurrently if existing
    add_index :orders, "LOWER(BTRIM(buyer_email))",
      name: INDEX_NAME,
      where: "user_id IS NULL", algorithm: :concurrently
  end

  def down
    remove_index :orders, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
  end
end
