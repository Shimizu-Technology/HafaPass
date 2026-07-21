# frozen_string_literal: true

class EventSeatingConfiguration < ApplicationRecord
  belongs_to :event
  belongs_to :venue_layout
  has_many :event_price_zones, dependent: :destroy
  has_many :event_seats, dependent: :restrict_with_error
  has_many :seat_hold_sessions, dependent: :restrict_with_error

  enum :status, { draft: 0, active: 1, locked: 2 }, prefix: true

  validates :event_id, uniqueness: true
  validate :layout_matches_event

  private

  def layout_matches_event
    return if event.nil? || venue_layout.nil?
    return if event.venue_id == venue_layout.venue_id && event.organization_id == venue_layout.organization_id

    errors.add(:venue_layout, "must belong to the event venue and organization")
  end
end
