class AddIndexesToOrders < ActiveRecord::Migration[8.0]
  def change
    add_index :orders, :source
    add_index :orders, :payment_method
  end
end
