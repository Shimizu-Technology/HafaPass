# frozen_string_literal: true

class PayoutLineAllocation < ApplicationRecord
  include AppendOnlyRecord

  belongs_to :payout
  belongs_to :order_item

  validates :order_item_id, uniqueness: { scope: :payout_id }
  validates :amount_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
