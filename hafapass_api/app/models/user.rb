class User < ApplicationRecord
  has_one :organizer_profile, dependent: :destroy
  has_many :orders, dependent: :nullify
  has_many :organization_memberships, dependent: :restrict_with_error
  has_many :organizations, through: :organization_memberships
  has_many :event_staff_assignments, dependent: :restrict_with_error

  enum :role, { attendee: 0, organizer: 1, admin: 2 }

  validates :clerk_id, presence: true, uniqueness: true
end
