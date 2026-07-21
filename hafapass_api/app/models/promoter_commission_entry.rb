# frozen_string_literal: true

class PromoterCommissionEntry < ApplicationRecord
  include AppendOnlyRecord

  belongs_to :promoter
  belongs_to :order
  belongs_to :refund, optional: true

  enum :kind, { earned: 0, refund_reversal: 1, payout: 2 }

  validates :amount_cents, numericality: { only_integer: true, other_than: 0 }
  validates :currency, presence: true, length: { is: 3 }
  validates :idempotency_key, presence: true, uniqueness: true
  validates :occurred_at, presence: true
end
