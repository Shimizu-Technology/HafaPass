# frozen_string_literal: true

class SeatingRow < ApplicationRecord
  belongs_to :seating_section
  has_many :venue_seats, -> { order(:position, :id) }, dependent: :destroy

  validates :label, presence: true, uniqueness: { scope: :seating_section_id }
end
