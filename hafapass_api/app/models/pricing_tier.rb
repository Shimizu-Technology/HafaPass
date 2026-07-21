class PricingTier < ApplicationRecord
  belongs_to :ticket_type
  has_many :tickets, dependent: :restrict_with_error
  has_many :order_items, dependent: :restrict_with_error
  has_many :inventory_holds, dependent: :restrict_with_error
  has_many :waitlist_offers, dependent: :restrict_with_error
  has_many :seat_holds, dependent: :restrict_with_error
  has_many :active_precheckout_seat_holds, -> {
    where(status: :active).joins(:seat_hold_session)
      .where(seat_hold_sessions: { status: SeatHoldSession.statuses[:active] })
      .where("seat_hold_sessions.expires_at > ?", Time.current)
  }, class_name: "SeatHold"

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

  def active?(at: Time.current)
    case tier_type
    when "quantity_based"
      quantity_sold + active_holds_quantity(at) + active_waitlist_quantity(at) + active_seat_holds_quantity(at) < quantity_limit
    when "time_based"
      if starts_at.present? && ends_at.present?
        at.between?(starts_at, ends_at)
      elsif starts_at.present?
        at >= starts_at
      elsif ends_at.present?
        at < ends_at
      else
        false
      end
    else
      false
    end
  end

  def active_seat_holds_quantity(at = Time.current)
    if active_precheckout_seat_holds.loaded?
      return active_precheckout_seat_holds.length
    end

    seat_holds.status_active.joins(:seat_hold_session)
      .where(seat_hold_sessions: { status: SeatHoldSession.statuses[:active] })
      .where("seat_hold_sessions.expires_at > ?", at).count
  end

  def remaining_quantity(at: Time.current)
    return unless quantity_based?

    [quantity_limit - quantity_sold - active_holds_quantity(at) - active_waitlist_quantity(at) -
      active_seat_holds_quantity(at), 0].max
  end

  private

  def active_holds_quantity(at)
    return inventory_holds.sum { |hold| hold.active? && hold.expires_at > at ? hold.quantity : 0 } if inventory_holds.loaded?

    inventory_holds.current.sum(:quantity)
  end

  def active_waitlist_quantity(at)
    if waitlist_offers.loaded?
      return waitlist_offers.sum { |offer| offer.offered? && offer.expires_at > at ? offer.quantity : 0 }
    end

    waitlist_offers.holding_inventory(at).sum(:quantity)
  end

  def chronological_time_window
    return unless time_based?

    errors.add(:ends_at, "must be after the tier start") if starts_at && ends_at && ends_at <= starts_at
  end

  def sold_quantity_within_limit
    return unless quantity_based? && quantity_limit.present?

    held = if persisted?
      inventory_holds.current.sum(:quantity) + waitlist_offers.holding_inventory.sum(:quantity) +
        active_seat_holds_quantity
    else
      0
    end
    committed = quantity_sold + held
    return if committed <= quantity_limit

    errors.add(:quantity_limit, "cannot be less than sold and actively held inventory")
  end
end
