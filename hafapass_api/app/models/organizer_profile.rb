class OrganizerProfile < ApplicationRecord
  belongs_to :user
  belongs_to :verified_by_user, class_name: "User", optional: true
  has_many :events, dependent: :destroy

  enum :verification_status, { unverified: 0, pending: 1, verified: 2, rejected: 3, suspended: 4 }, prefix: true

  validates :business_name, presence: true
  validates :user_id, uniqueness: true
  validates :verification_notes, presence: true, if: -> { verification_status_rejected? || verification_status_suspended? }

  def policy_accepted?
    policy_accepted_at.present?
  end

  def ready_to_publish_free_events?
    verification_status_verified? && policy_accepted?
  end

  def ready_to_publish_paid_events?
    ready_to_publish_free_events? && payout_ready?
  end
end
