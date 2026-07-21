# frozen_string_literal: true

class VenueLayout < ApplicationRecord
  belongs_to :venue
  belongs_to :organization
  has_many :seating_sections, -> { order(:position, :id) }, dependent: :destroy
  has_many :seating_price_zones, -> { order(:position, :id) }, dependent: :destroy
  has_many :seating_rows, through: :seating_sections
  has_many :venue_seats, through: :seating_rows
  has_many :event_seating_configurations, dependent: :restrict_with_error

  enum :status, { draft: 0, published: 1, retired: 2 }, prefix: true
  enum :renderer, { internal: 0, seats_io: 1 }, prefix: true

  validates :name, presence: true
  validates :version, numericality: { only_integer: true, greater_than: 0 }
  validates :name, uniqueness: { scope: [:organization_id, :venue_id, :version] }
  validates :provider_chart_key, presence: true, if: :renderer_seats_io?
end
