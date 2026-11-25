# frozen_string_literal: true

# The fulfilling payment must be a payment on the same order. Added NOT VALID
# (a brief lock on orders and payments) and validated separately.
class AddFulfilledByPaymentForeignKey < ActiveRecord::Migration[8.1]
  def change
    add_foreign_key :orders, :payments, column: [:fulfilled_by_payment_id, :id], primary_key: [:id, :order_id],
      name: "fk_orders_fulfilled_by_same_order_payment", validate: false
  end
end
