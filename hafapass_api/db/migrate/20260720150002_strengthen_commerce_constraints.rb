# frozen_string_literal: true

class StrengthenCommerceConstraints < ActiveRecord::Migration[8.1]
  def change
    add_check_constraint :orders,
      "discount_cents <= subtotal_cents + service_fee_cents",
      name: "orders_discount_within_charge"
    add_check_constraint :orders,
      "total_cents = GREATEST(subtotal_cents + service_fee_cents - discount_cents, 0)",
      name: "orders_total_matches_components"
    add_check_constraint :orders, "refund_amount_cents <= total_cents", name: "orders_refund_within_total"
    add_check_constraint :ticket_types, "quantity_sold <= quantity_available", name: "ticket_types_sold_within_capacity"
    add_check_constraint :pricing_tiers, "price_cents >= 0", name: "pricing_tiers_price_nonnegative"
    add_check_constraint :pricing_tiers, "quantity_sold >= 0", name: "pricing_tiers_sold_nonnegative"
    add_check_constraint :pricing_tiers,
      "tier_type != 1 OR quantity_sold <= quantity_limit",
      name: "pricing_tiers_sold_within_limit"
    add_check_constraint :order_items,
      "organizer_proceeds_cents <= subtotal_cents",
      name: "order_items_proceeds_within_subtotal"
  end
end
