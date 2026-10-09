class IndexUnownedOrdersForGuestRecovery < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :orders, "LOWER(BTRIM(buyer_email))",
      name: "index_orders_on_normalized_guest_buyer_email",
      where: "user_id IS NULL", algorithm: :concurrently
  end
end
