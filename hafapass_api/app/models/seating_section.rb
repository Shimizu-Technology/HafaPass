# frozen_string_literal: true

class SeatingSection < ApplicationRecord
  belongs_to :venue_layout
  has_many :seating_rows, -> { order(:position, :id) }, dependent: :destroy
  has_many :venue_seats, through: :seating_rows

  validates :name, :code, presence: true
  validates :code, uniqueness: { scope: :venue_layout_id }
end
