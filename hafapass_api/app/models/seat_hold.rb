# frozen_string_literal: true

class SeatHold < ApplicationRecord
  belongs_to :seat_hold_session
  belongs_to :event_seat
  belongs_to :order_item, optional: true
  belongs_to :pricing_tier, optional: true

  enum :status, { active: 0, claimed: 1, consumed: 2, released: 3, expired: 4 }, prefix: true

  validates :event_seat_id, uniqueness: { scope: :seat_hold_session_id }
  validate :references_match_session

  private

  def references_match_session
    return unless seat_hold_session && event_seat
    unless event_seat.event_seating_configuration_id == seat_hold_session.event_seating_configuration_id
      errors.add(:event_seat, "must belong to the hold session event")
    end
    if pricing_tier && pricing_tier.ticket_type_id != event_seat.ticket_type_id
      errors.add(:pricing_tier, "must belong to the seat ticket type")
    end
    return unless order_item

    errors.add(:order_item, "must belong to the claimed order") unless order_item.order_id == seat_hold_session.order_id
    errors.add(:order_item, "must match the seat ticket type") unless order_item.ticket_type_id == event_seat.ticket_type_id
  end
end
