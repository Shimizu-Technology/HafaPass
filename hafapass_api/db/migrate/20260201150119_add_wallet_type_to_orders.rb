class AddWalletTypeToOrders < ActiveRecord::Migration[8.1]
  def change
    add_column :orders, :wallet_type, :string  # apple_pay, google_pay, card, or nil
  end
end
