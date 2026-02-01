class AddPromoCodeToOrders < ActiveRecord::Migration[8.1]
  def change
    add_reference :orders, :promo_code, null: true, foreign_key: true
    add_column :orders, :discount_cents, :integer, null: false, default: 0
  end
end
