class AddBoxOfficeFieldsToOrders < ActiveRecord::Migration[8.1]
  def change
    add_column :orders, :source, :string
    add_column :orders, :payment_method, :string
  end
end
