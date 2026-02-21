class TicketType < ApplicationRecord
  belongs_to :event
  has_many :tickets, dependent: :restrict_with_error
  has_many :pricing_tiers, -> { order(:position) }, dependent: :destroy

  validates :name, presence: true
  validates :price_cents, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :quantity_available, presence: true, numericality: { greater_than: 0 }

  def sold_out?
    quantity_sold >= quantity_available
  end

  def available_quantity
    quantity_available - quantity_sold
  end

  # Evaluates pricing tiers in order and returns the current effective price
  def current_price_cents
    pricing_tiers.each do |tier|
      case tier.tier_type
      when 'quantity_based'
        return tier.price_cents if tier.quantity_sold < tier.quantity_limit
      when 'time_based'
        if tier.starts_at.present? && tier.ends_at.present?
          return tier.price_cents if Time.current.between?(tier.starts_at, tier.ends_at)
        elsif tier.ends_at.present?
          return tier.price_cents if Time.current < tier.ends_at
        end
      end
    end
    price_cents # fallback to base price
  end

  # Returns the currently active pricing tier, or nil if using base price
  def active_pricing_tier
    pricing_tiers.each do |tier|
      return tier if tier.active?
    end
    nil
  end

  # Returns the next tier that will become active after the current one
  def next_pricing_tier
    found_active = false
    pricing_tiers.each do |tier|
      return tier if found_active
      found_active = true if tier.active?
    end
    nil
  end
end
