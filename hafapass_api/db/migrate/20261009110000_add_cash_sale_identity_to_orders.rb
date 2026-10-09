class AddCashSaleIdentityToOrders < ActiveRecord::Migration[8.0]
  def change
    add_column :orders, :cash_sale_key, :string
    add_column :orders, :cash_sale_request_digest, :string
    add_index :orders, :cash_sale_key, unique: true
  end
end
