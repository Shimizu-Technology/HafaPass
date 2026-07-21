class TicketType < ApplicationRecord
  belongs_to :event
  has_many :tickets, dependent: :restrict_with_error
  has_many :order_items, dependent: :restrict_with_error
  has_many :inventory_holds, dependent: :restrict_with_error
  has_many :pricing_tiers, -> { order(:position) }, dependent: :destroy
  has_many :waitlist_offers, dependent: :restrict_with_error

  validates :name, presence: true
  validates :price_cents, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :quantity_available, presence: true, numericality: { greater_than: 0 }
  validates :quantity_sold, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :max_per_buyer, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :door_allocation, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validate :sold_quantity_within_capacity
  validate :door_allocation_within_capacity
  validate :chronological_sales_window

  def sold_out?
    available_quantity.zero?
  end

  def available_quantity
    [quantity_available - quantity_sold - active_holds_quantity - active_waitlist_offer_quantity, 0].max
  end

  def active_holds_quantity
    inventory_holds.current.sum(:quantity)
  end

  def active_waitlist_offer_quantity
    waitlist_offers.holding_inventory.sum(:quantity)
  end

  def door_sold_quantity
    tickets.joins(:order).where(orders: { source: "box_office" }).where.not(status: :cancelled).count
  end

  def door_held_quantity
    inventory_holds.current.joins(:order).where(orders: { source: "box_office" }).sum(:quantity)
  end

  def door_available_quantity
    return available_quantity if door_allocation.nil?

    [available_quantity, [door_allocation - door_sold_quantity - door_held_quantity, 0].max].min
  end

  def on_sale?(at: Time.current)
    (sales_start_at.nil? || sales_start_at <= at) &&
      (sales_end_at.nil? || sales_end_at > at)
  end

  # Evaluates pricing tiers in order and returns the current effective price.
  def current_price_cents
    pricing_tiers.each do |tier|
      case tier.tier_type
      when "quantity_based"
        return tier.price_cents if tier.active?
      when "time_based"
        if tier.starts_at.present? && tier.ends_at.present?
          return tier.price_cents if Time.current.between?(tier.starts_at, tier.ends_at)
        elsif tier.starts_at.present?
          return tier.price_cents if Time.current >= tier.starts_at
        elsif tier.ends_at.present?
          return tier.price_cents if Time.current < tier.ends_at
        end
      end
    end
    price_cents
  end

  # Returns the currently active pricing tier, or nil if using base price.
  def active_pricing_tier
    pricing_tiers.each do |tier|
      return tier if tier.active?
    end
    nil
  end

  # Returns the next tier that will become active after the current one.
  def next_pricing_tier
    tiers = pricing_tiers.to_a
    active_index = tiers.index(&:active?)
    return tiers[active_index + 1] if active_index

    tiers.find { |tier| tier.time_based? && tier.starts_at.present? && tier.starts_at > Time.current }
  end

  private

  def chronological_sales_window
    errors.add(:sales_end_at, "must be after sales start") if sales_start_at && sales_end_at && sales_end_at <= sales_start_at
    errors.add(:sales_start_at, "must be before the event ends") if sales_start_at && event&.ends_at && sales_start_at >= event.ends_at
    errors.add(:sales_end_at, "must be at or before the event end") if sales_end_at && event&.ends_at && sales_end_at > event.ends_at
  end

  def sold_quantity_within_capacity
    return if quantity_sold.blank? || quantity_available.blank?

    committed = quantity_sold + (persisted? ? active_holds_quantity : 0)
    return if committed <= quantity_available

    errors.add(:quantity_available, "cannot be less than sold and actively held inventory")
  end

  def door_allocation_within_capacity
    return if door_allocation.nil? || quantity_available.nil? || door_allocation <= quantity_available

    errors.add(:door_allocation, "cannot exceed total ticket inventory")
  end
end
