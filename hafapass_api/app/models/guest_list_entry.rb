# frozen_string_literal: true

class GuestListEntry < ApplicationRecord
  belongs_to :event
  belongs_to :ticket_type
  belongs_to :order, optional: true

  validates :guest_name, presence: true
  validates :quantity, presence: true, numericality: { greater_than: 0, less_than_or_equal_to: 10 }

  scope :unredeemed, -> { where(redeemed: false) }
  scope :redeemed, -> { where(redeemed: true) }

  def redeem!(order)
    update!(
      redeemed: true,
      order: order
    )
  end
end
