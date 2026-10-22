# frozen_string_literal: true

# An admin's email invitation for someone to join HåfaPass staff. The role is
# applied only after that person signs in with the invited, verified email.
class PlatformInvitation < ApplicationRecord
  LIFETIME = 14.days

  belongs_to :invited_by_user, class_name: "User"
  belongs_to :accepted_by_user, class_name: "User", optional: true
  has_many :message_deliveries, dependent: :restrict_with_error

  enum :role, { admin: 2, support: 3 }
  enum :status, { pending: 0, accepted: 1, revoked: 2 }, prefix: true

  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :invited_at, :expires_at, presence: true

  before_validation { self.email = email.to_s.strip.downcase }

  scope :unexpired_pending, ->(at = Time.current) { status_pending.where("expires_at > ?", at) }

  def display_status(at: Time.current)
    return status unless status_pending?

    expires_at > at ? "pending" : "expired"
  end
end
