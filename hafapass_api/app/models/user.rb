class User < ApplicationRecord
  enum :role, { attendee: 0, organizer: 1, admin: 2 }

  validates :clerk_id, presence: true, uniqueness: true
end
