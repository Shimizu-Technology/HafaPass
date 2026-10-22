# frozen_string_literal: true

class PayoutCheckAdjustment < ApplicationRecord
  include AppendOnlyRecord

  belongs_to :payout
  belongs_to :created_by_user, class_name: "User"

  validates :amount_cents, numericality: { only_integer: true, other_than: 0 }
  validates :reason, presence: true, length: { in: 10..1000 }
end
