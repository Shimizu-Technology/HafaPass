class User < ApplicationRecord
  has_one :organizer_profile, dependent: :destroy
  has_many :orders, dependent: :nullify
  has_many :organization_memberships, dependent: :restrict_with_error
  has_many :organizations, through: :organization_memberships
  has_many :event_staff_assignments, dependent: :restrict_with_error
  has_many :scanner_devices, dependent: :restrict_with_error
  has_many :admission_actions, foreign_key: :actor_user_id, dependent: :restrict_with_error,
    inverse_of: :actor_user
  has_many :verified_card_present_accounts, class_name: "CardPresentAccount", foreign_key: :verified_by_user_id,
    dependent: :restrict_with_error, inverse_of: :verified_by_user
  has_many :card_present_payment_attempts, foreign_key: :initiated_by_user_id,
    dependent: :restrict_with_error, inverse_of: :initiated_by_user

  enum :role, { attendee: 0, organizer: 1, admin: 2 }

  validates :clerk_id, presence: true, uniqueness: true
end
