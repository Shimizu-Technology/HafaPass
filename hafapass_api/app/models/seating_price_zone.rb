# frozen_string_literal: true

class SeatingPriceZone < ApplicationRecord
  belongs_to :venue_layout
  has_many :venue_seats, dependent: :restrict_with_error
  has_many :event_price_zones, dependent: :restrict_with_error

  validates :name, :code, :color, presence: true
  validates :code, uniqueness: { scope: :venue_layout_id }
  validate :valid_color

  private

  def valid_color
    errors.add(:color, "must be a hex color") unless color.to_s.match?(/\A#[0-9A-Fa-f]{6}\z/)
  end
end
