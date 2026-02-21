class AddIndexesToOrders < ActiveRecord::Migration[8.1]
  def change
    add_index :orders, :source
    add_index :orders, :payment_method
  end
end
