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
  has_many :support_notes, foreign_key: :author_user_id, dependent: :restrict_with_error, inverse_of: :author_user
  has_many :held_tickets, class_name: "Ticket", foreign_key: :holder_user_id, dependent: :restrict_with_error
  has_many :initiated_ticket_transfers, class_name: "TicketTransfer", foreign_key: :initiated_by_user_id,
    dependent: :restrict_with_error
  has_many :accepted_ticket_transfers, class_name: "TicketTransfer", foreign_key: :accepted_by_user_id,
    dependent: :restrict_with_error
  has_many :communication_campaigns, foreign_key: :created_by_user_id, dependent: :restrict_with_error
  has_many :event_favorites, dependent: :destroy
  has_many :favorite_events, through: :event_favorites, source: :event
  has_many :organizer_follows, dependent: :destroy
  has_many :followed_organizations, through: :organizer_follows, source: :organization
  has_many :event_reminders, dependent: :destroy
  has_many :marketplace_collections, foreign_key: :created_by_user_id, dependent: :restrict_with_error
  has_many :distribution_links, foreign_key: :created_by_user_id, dependent: :restrict_with_error
  has_many :event_referrals, dependent: :destroy
  has_many :seat_hold_sessions, dependent: :nullify
  has_many :seat_audit_events, foreign_key: :actor_user_id, dependent: :nullify
  has_many :accessible_seat_releases, foreign_key: :released_by_user_id, dependent: :restrict_with_error
  has_many :payment_readiness_reviews, foreign_key: :actor_user_id, dependent: :restrict_with_error,
    inverse_of: :actor_user
  has_many :platform_capability_reviews, foreign_key: :actor_user_id, dependent: :restrict_with_error,
    inverse_of: :actor_user
  has_many :pilot_readiness_reviews, foreign_key: :actor_user_id, dependent: :restrict_with_error,
    inverse_of: :actor_user
  has_many :pilot_validation_reviews, foreign_key: :actor_user_id, dependent: :restrict_with_error,
    inverse_of: :actor_user

  enum :role, { attendee: 0, organizer: 1, admin: 2, support: 3 }

  validates :clerk_id, presence: true, uniqueness: true
end
