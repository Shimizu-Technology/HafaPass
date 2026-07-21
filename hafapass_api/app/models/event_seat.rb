# frozen_string_literal: true

class EventSeat < ApplicationRecord
  belongs_to :event_seating_configuration
  belongs_to :venue_seat
  belongs_to :ticket_type
  has_many :seat_holds, dependent: :restrict_with_error
  has_many :tickets, dependent: :restrict_with_error
  has_many :active_tickets, -> { where(status: [:issued, :checked_in, :transferred]) }, class_name: "Ticket"
  has_many :blocking_seat_holds, -> {
    where(status: [:active, :claimed]).joins(:seat_hold_session)
      .where("seat_hold_sessions.expires_at > ?", Time.current)
  }, class_name: "SeatHold"
  has_many :active_precheckout_seat_holds, -> {
    where(status: :active).joins(:seat_hold_session)
      .where(seat_hold_sessions: { status: SeatHoldSession.statuses[:active] })
      .where("seat_hold_sessions.expires_at > ?", Time.current)
  }, class_name: "SeatHold"
  has_one :accessible_seat_release, dependent: :restrict_with_error

  enum :operational_status, { available: 0, blocked: 1, house_hold: 2 }, prefix: true

  validates :venue_seat_id, uniqueness: { scope: :event_seating_configuration_id }
  validate :references_match_configuration

  delegate :display_label, :accessibility_kind, :companion_group, :obstructed_view, :view_note,
    to: :venue_seat

  def accessible_inventory?
    !venue_seat.accessibility_kind_standard?
  end

  def generally_released?(at: Time.current)
    general_release_at.present? && general_release_at <= at
  end

  def active_ticket
    active_tickets.first
  end

  def blocking_hold(at: Time.current)
    return blocking_seat_holds.first if blocking_seat_holds.loaded?

    seat_holds.where(status: [:active, :claimed]).joins(:seat_hold_session)
      .where("seat_hold_sessions.expires_at > ?", at).first
  end

  def selectable?(at: Time.current)
    operational_status_available? && active_ticket.nil? && blocking_hold(at: at).nil?
  end

  private

  def references_match_configuration
    return unless event_seating_configuration && venue_seat && ticket_type
    unless venue_seat.seating_row.seating_section.venue_layout_id == event_seating_configuration.venue_layout_id
      errors.add(:venue_seat, "must belong to the configured layout")
    end
    unless ticket_type.event_id == event_seating_configuration.event_id
      errors.add(:ticket_type, "must belong to the configured event")
    end
  end
end
