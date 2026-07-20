# frozen_string_literal: true

class AddRefundAllocationComponents < ActiveRecord::Migration[8.1]
  class LegacyRefundItem < ActiveRecord::Base
    self.table_name = "refund_items"
  end

  class LegacyOrderItem < ActiveRecord::Base
    self.table_name = "order_items"
  end

  def up
    add_column :refund_items, :organizer_proceeds_cents, :integer, null: false, default: 0
    add_column :refund_items, :fee_cents, :integer, null: false, default: 0
    add_column :refund_items, :tax_cents, :integer, null: false, default: 0

    LegacyRefundItem.reset_column_information
    LegacyRefundItem.find_each { |refund_item| backfill_components(refund_item) }

    add_check_constraint :refund_items, "organizer_proceeds_cents >= 0",
      name: "refund_items_proceeds_nonnegative"
    add_check_constraint :refund_items, "fee_cents >= 0", name: "refund_items_fee_nonnegative"
    add_check_constraint :refund_items, "tax_cents >= 0", name: "refund_items_tax_nonnegative"
    add_check_constraint :refund_items,
      "amount_cents = organizer_proceeds_cents + fee_cents + tax_cents",
      name: "refund_items_components_match_amount"
  end

  def down
    remove_check_constraint :refund_items, name: "refund_items_components_match_amount"
    remove_check_constraint :refund_items, name: "refund_items_tax_nonnegative"
    remove_check_constraint :refund_items, name: "refund_items_fee_nonnegative"
    remove_check_constraint :refund_items, name: "refund_items_proceeds_nonnegative"
    remove_column :refund_items, :tax_cents
    remove_column :refund_items, :fee_cents
    remove_column :refund_items, :organizer_proceeds_cents
  end

  private

  def backfill_components(refund_item)
    item = LegacyOrderItem.find(refund_item.order_item_id)
    allocations = allocate(
      refund_item.amount_cents,
      [item.organizer_proceeds_cents, item.fee_cents, item.tax_cents]
    )
    refund_item.update_columns(
      organizer_proceeds_cents: allocations[0],
      fee_cents: allocations[1],
      tax_cents: allocations[2]
    )
  end

  def allocate(total, weights)
    return [total, 0, 0] if weights.sum.zero?

    result = weights.map { |weight| (total * weight).div(weights.sum) }
    (total - result.sum).times { |index| result[index % result.length] += 1 }
    result
  end
end
