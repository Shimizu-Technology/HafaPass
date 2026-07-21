# frozen_string_literal: true

class EventPriceZone < ApplicationRecord
  belongs_to :event_seating_configuration
  belongs_to :seating_price_zone
  belongs_to :ticket_type

  validates :seating_price_zone_id, uniqueness: { scope: :event_seating_configuration_id }
  validate :references_match_configuration

  private

  def references_match_configuration
    return unless event_seating_configuration && seating_price_zone && ticket_type
    unless seating_price_zone.venue_layout_id == event_seating_configuration.venue_layout_id
      errors.add(:seating_price_zone, "must belong to the configured layout")
    end
    unless ticket_type.event_id == event_seating_configuration.event_id
      errors.add(:ticket_type, "must belong to the configured event")
    end
  end
end
