# frozen_string_literal: true

class AddOrganizerFeeToRefundItems < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :refund_items, name: "refund_items_components_match_amount"
    add_column :refund_items, :organizer_fee_cents, :integer, null: false, default: 0
    add_check_constraint :refund_items, "organizer_fee_cents >= 0", name: "refund_items_organizer_fee_nonnegative"
    add_check_constraint :refund_items,
      "amount_cents = (organizer_proceeds_cents + fee_cents + organizer_fee_cents + tax_cents)",
      name: "refund_items_components_match_amount"
  end

  def down
    remove_check_constraint :refund_items, name: "refund_items_components_match_amount"
    remove_check_constraint :refund_items, name: "refund_items_organizer_fee_nonnegative"
    remove_column :refund_items, :organizer_fee_cents
    add_check_constraint :refund_items,
      "amount_cents = (organizer_proceeds_cents + fee_cents + tax_cents)",
      name: "refund_items_components_match_amount"
  end
end
