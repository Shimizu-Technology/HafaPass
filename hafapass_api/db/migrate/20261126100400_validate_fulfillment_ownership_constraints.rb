# frozen_string_literal: true

class ValidateFulfillmentOwnershipConstraints < ActiveRecord::Migration[8.1]
  def change
    validate_check_constraint :orders, name: "orders_never_fulfilled_not_completed"
    validate_check_constraint :orders, name: "orders_fulfilled_xor_never_fulfilled"
    validate_foreign_key :orders, name: "fk_orders_fulfilled_by_same_order_payment"
  end
end
