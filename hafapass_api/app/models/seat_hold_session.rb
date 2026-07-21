# frozen_string_literal: true

class SeatHoldSession < ApplicationRecord
  belongs_to :event_seating_configuration
  belongs_to :order, optional: true
  belongs_to :user, optional: true
  has_many :seat_holds, dependent: :restrict_with_error
  has_many :event_seats, through: :seat_holds

  enum :status, { active: 0, claimed: 1, consumed: 2, released: 3, expired: 4 }, prefix: true

  validates :token_digest, presence: true, uniqueness: true
  validates :expires_at, presence: true

  def usable?(at: Time.current)
    (status_active? || status_claimed?) && expires_at > at
  end
end
