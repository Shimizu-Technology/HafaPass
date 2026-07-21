# frozen_string_literal: true

class AccessibleSeatRelease < ApplicationRecord
  belongs_to :event_seat
  belongs_to :released_by_user, class_name: "User"

  RELEASE_SCOPES = %w[venue section price_zone].freeze

  validates :release_scope, inclusion: { in: RELEASE_SCOPES }
  validates :reason, :released_at, presence: true
  validates :event_seat_id, uniqueness: true
end
