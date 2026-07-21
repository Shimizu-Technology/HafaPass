# frozen_string_literal: true

class OrderItem < ApplicationRecord
  include AppendOnlyRecord

  belongs_to :order
  belongs_to :ticket_type, optional: true
  belongs_to :pricing_tier, optional: true
  belongs_to :catalog_item, optional: true
  has_one :inventory_hold, dependent: :restrict_with_error
  has_many :tickets, dependent: :restrict_with_error
  has_many :fee_components, dependent: :restrict_with_error
  has_many :refund_items, dependent: :restrict_with_error
  has_one :catalog_item_hold, dependent: :restrict_with_error
  has_one :catalog_fulfillment, dependent: :restrict_with_error
  has_many :seat_holds, dependent: :restrict_with_error

  enum :item_kind, { ticket: 0, add_on: 1, merchandise: 2, concession: 3, donation: 4 }, prefix: :item

  validates :name, :currency, presence: true
  validates :currency, length: { is: 3 }
  validates :quantity, numericality: { only_integer: true, greater_than: 0 }
  validates :unit_price_cents, :subtotal_cents, :discount_cents, :fee_cents, :tax_cents,
    :organizer_proceeds_cents, :organizer_fee_cents,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :subtotal_matches_quantity
  validate :catalog_or_ticket

  def refundable_cents
    [subtotal_cents + tax_cents + fee_cents - discount_cents - refund_items.sum(:amount_cents), 0].max
  end

  private

  def subtotal_matches_quantity
    return if unit_price_cents.blank? || quantity.blank?
    return if subtotal_cents == unit_price_cents * quantity

    errors.add(:subtotal_cents, "must equal unit price times quantity")
  end

  def catalog_or_ticket
    valid = item_ticket? ? ticket_type.present? && catalog_item.nil? : catalog_item.present? && ticket_type.nil?
    errors.add(:base, "Order item must reference its ticket type or catalog item") unless valid
  end
end
