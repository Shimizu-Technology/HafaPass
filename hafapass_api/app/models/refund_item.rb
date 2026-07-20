# frozen_string_literal: true

class RefundItem < ApplicationRecord
  include AppendOnlyRecord

  belongs_to :refund
  belongs_to :order_item

  validates :order_item_id, uniqueness: { scope: :refund_id }
  validates :amount_cents, :quantity, :organizer_proceeds_cents, :fee_cents, :tax_cents,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :item_belongs_to_refund_order
  validate :components_match_amount

  private

  def item_belongs_to_refund_order
    return if refund.blank? || order_item.blank? || refund.order_id == order_item.order_id

    errors.add(:order_item, "must belong to the refunded order")
  end

  def components_match_amount
    components = [organizer_proceeds_cents, fee_cents, tax_cents]
    return if amount_cents.nil? || components.any?(&:nil?) || amount_cents == components.sum

    errors.add(:amount_cents, "must equal organizer, fee, and tax refund components")
  end
end
