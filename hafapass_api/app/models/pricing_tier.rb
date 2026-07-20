class PricingTier < ApplicationRecord
  belongs_to :ticket_type
  has_many :tickets, dependent: :restrict_with_error
  has_many :order_items, dependent: :restrict_with_error
  has_many :inventory_holds, dependent: :restrict_with_error

  enum :tier_type, { time_based: 0, quantity_based: 1 }

  validates :name, presence: true
  validates :price_cents, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :tier_type, presence: true
  validates :quantity_limit, presence: true, numericality: { greater_than: 0 }, if: :quantity_based?
  validates :position, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :quantity_sold, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :sold_quantity_within_limit
  validate :chronological_time_window

  scope :ordered, -> { order(:position) }

  def active?
    case tier_type
    when "quantity_based"
      quantity_sold + inventory_holds.current.sum(:quantity) < quantity_limit
    when "time_based"
      if starts_at.present? && ends_at.present?
        Time.current.between?(starts_at, ends_at)
      elsif starts_at.present?
        Time.current >= starts_at
      elsif ends_at.present?
        Time.current < ends_at
      else
        false
      end
    else
      false
    end
  end
  private

  def chronological_time_window
    return unless time_based?

    errors.add(:ends_at, "must be after the tier start") if starts_at && ends_at && ends_at <= starts_at
  end

  def sold_quantity_within_limit
    return unless quantity_based? && quantity_limit.present?

    committed = quantity_sold + (persisted? ? inventory_holds.current.sum(:quantity) : 0)
    return if committed <= quantity_limit

    errors.add(:quantity_limit, "cannot be less than sold and actively held inventory")
  end
end
