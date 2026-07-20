# frozen_string_literal: true

class PromoRedemption < ApplicationRecord
  belongs_to :promo_code
  belongs_to :order

  enum :status, { reserved: 0, finalized: 1, released: 2 }

  validates :order_id, uniqueness: true
  validates :discount_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :capacity_consuming, -> { where(status: [:reserved, :finalized]) }
end
