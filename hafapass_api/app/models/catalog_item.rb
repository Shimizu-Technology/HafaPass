# frozen_string_literal: true

class CatalogItem < ApplicationRecord
  belongs_to :event
  has_many :order_items, dependent: :restrict_with_error
  has_many :catalog_item_holds, dependent: :restrict_with_error

  enum :kind, { add_on: 1, merchandise: 2, concession: 3, donation: 4 }

  validates :name, presence: true
  validates :price_cents, :quantity_sold, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :minimum_price_cents, :maximum_price_cents,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :inventory_quantity, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :donation_price_range
  validate :inventory_covers_commitments

  scope :available, -> { where(active: true).order(:position, :id) }

  def active_holds_quantity
    catalog_item_holds.current.sum(:quantity)
  end

  def available_quantity
    return Float::INFINITY if inventory_quantity.nil?

    [inventory_quantity - quantity_sold - active_holds_quantity, 0].max
  end

  def price_for(requested_cents = nil)
    return price_cents unless donation?

    amount = requested_cents.to_i
    minimum = minimum_price_cents || price_cents
    raise ArgumentError, "Donation is below the minimum" if amount < minimum
    raise ArgumentError, "Donation exceeds the maximum" if maximum_price_cents && amount > maximum_price_cents

    amount
  end

  private

  def donation_price_range
    if minimum_price_cents && maximum_price_cents && minimum_price_cents > maximum_price_cents
      errors.add(:maximum_price_cents, "must be at least the minimum")
    end
    if !donation? && (minimum_price_cents.present? || maximum_price_cents.present?)
      errors.add(:base, "Only donations can define a custom price range")
    end
  end

  def inventory_covers_commitments
    return if inventory_quantity.nil? || !persisted?
    return if inventory_quantity >= quantity_sold + active_holds_quantity

    errors.add(:inventory_quantity, "cannot be less than sold and actively held inventory")
  end
end
