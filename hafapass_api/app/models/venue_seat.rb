# frozen_string_literal: true

class VenueSeat < ApplicationRecord
  belongs_to :seating_row
  belongs_to :seating_price_zone
  has_one :seating_section, through: :seating_row
  has_many :event_seats, dependent: :restrict_with_error

  enum :accessibility_kind, { standard: 0, wheelchair: 1, companion: 2, limited_mobility: 3 }, prefix: true

  validates :label, presence: true, uniqueness: { scope: :seating_row_id }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 },
    uniqueness: { scope: :seating_row_id }
  validate :zone_belongs_to_layout

  def display_label
    "#{seating_row.seating_section.name} · Row #{seating_row.label} · Seat #{label}"
  end

  private

  def zone_belongs_to_layout
    return if seating_price_zone.nil? || seating_row.nil?
    return if seating_price_zone.venue_layout_id == seating_row.seating_section.venue_layout_id

    errors.add(:seating_price_zone, "must belong to the same layout")
  end
end
