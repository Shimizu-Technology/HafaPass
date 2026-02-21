class PricingTier < ApplicationRecord
  belongs_to :ticket_type

  enum :tier_type, { time_based: 0, quantity_based: 1 }

  validates :name, presence: true
  validates :price_cents, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :tier_type, presence: true
  validates :quantity_limit, presence: true, numericality: { greater_than: 0 }, if: :quantity_based?
  validates :position, presence: true, numericality: { greater_than_or_equal_to: 0 }

  scope :ordered, -> { order(:position) }

  def active?
    case tier_type
    when 'quantity_based'
      quantity_sold < quantity_limit
    when 'time_based'
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
end
