class AddRefundFieldsToOrders < ActiveRecord::Migration[8.1]
  def change
    add_column :orders, :refund_amount_cents, :integer, default: 0, null: false
    add_column :orders, :refund_reason, :string
    add_column :orders, :refunded_at, :datetime
    add_column :orders, :stripe_refund_id, :string
  end
end
