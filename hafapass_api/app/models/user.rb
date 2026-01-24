class User < ApplicationRecord
  has_one :organizer_profile, dependent: :destroy
  has_many :orders, dependent: :nullify

  enum :role, { attendee: 0, organizer: 1, admin: 2 }

  validates :clerk_id, presence: true, uniqueness: true
end
