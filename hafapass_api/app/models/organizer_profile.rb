class OrganizerProfile < ApplicationRecord
  # The person who set up the profile. Admin-created organizations have none
  # until the invited owner accepts.
  belongs_to :user, optional: true
  belongs_to :organization
  belongs_to :verified_by_user, class_name: "User", optional: true
  has_many :events, dependent: :destroy

  enum :verification_status, { unverified: 0, pending: 1, verified: 2, rejected: 3, suspended: 4 }, prefix: true

  validates :business_name, presence: true
  validate :logo_image_is_approved
  validates :user_id, uniqueness: true, allow_nil: true

  def logo_image_is_approved
    return unless new_record? || will_save_change_to_logo_url? || will_save_change_to_organization_id?
    return if logo_url.blank? || ApprovedImageUrl.valid?(logo_url, organization_id: organization_id)

    errors.add(:logo_url, ApprovedImageUrl::MESSAGE)
  end
  # A rejection tells the organizer what to fix. Suspending ("Pause all sales")
  # is one admin action; its note is optional.
  validates :verification_notes, presence: true, if: -> { verification_status_rejected? }

  def policy_accepted?(current: PolicyRegistry.organizer_agreement)
    policy_accepted_at.present? && policy_version == current[:version] && policy_digest == current[:digest]
  end

  # Production lets unverified organizers publish (tickets sell only once
  # verified); elsewhere verification is still needed to publish.
  def ready_to_publish_free_events?
    (verification_status_verified? || Rails.env.production?) && policy_accepted?
  end

  def ready_to_publish_paid_events?
    ready_to_publish_free_events? && organization.payout_ready?
  end
end
