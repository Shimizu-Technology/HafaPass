class AddSoldByToOrders < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_reference :orders, :sold_by, index: { algorithm: :concurrently }, foreign_key: false
    add_foreign_key :orders, :users, column: :sold_by_id, validate: false
  end
end
