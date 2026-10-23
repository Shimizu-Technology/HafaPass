class OrganizerProfile < ApplicationRecord
  VERIFICATION_DETAILS = %w[business_name business_description verification_phone verification_link verification_request_note].freeze

  def verification_details
    attributes.slice(*VERIFICATION_DETAILS)
  end

  def refresh_verification_request!(before_details:, was_pending:)
    changes = before_details.each_with_object({}) do |(field, before), diff|
      after = public_send(field)
      diff[field] = { "before" => before, "after" => after } if before != after
    end
    return false if was_pending && changes.empty?

    self.verification_request_version += 1
    self.verification_requested_at = Time.current
    self.verification_change_diff = was_pending ? changes : {}
    true
  end

  def self.verification_gate_enabled?
    Rails.env.production? || ENV["HAFAPASS_ENFORCE_ORGANIZER_VERIFICATION"] == "true"
  end
  # The person who set up the profile. Admin-created organizations have none
  # until the invited owner accepts.
  belongs_to :user, optional: true
  belongs_to :organization
  belongs_to :verified_by_user, class_name: "User", optional: true
  has_many :events, dependent: :destroy

  enum :verification_status, { unverified: 0, pending: 1, verified: 2, rejected: 3, suspended: 4 }, prefix: true

  validates :business_name, presence: true
  validates :business_description, :verification_phone, :verification_link, presence: true,
    on: :verification_request
  validate :verification_contact_format, on: :verification_request
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

  def verification_contact_format
    digits = verification_phone.to_s.gsub(/\D/, "")
    unless digits.match?(/\A(?:1671|671)\d{7}\z/) || digits.match?(/\A1[2-9]\d{9}\z/)
      errors.add(:verification_phone, "must be a valid phone number (Guam +1-671 is accepted)")
    end
    uri = URI.parse(verification_link.to_s)
    unless %w[http https].include?(uri.scheme) && uri.host.present? && uri.host.include?(".")
      errors.add(:verification_link, "must be a full website or social media URL")
    end
  rescue URI::InvalidURIError
    errors.add(:verification_link, "must be a full website or social media URL")
  end

  def policy_accepted?(current: PolicyRegistry.organizer_agreement)
    policy_accepted_at.present? && policy_version == current[:version] && policy_digest == current[:digest]
  end

  # Production lets unverified organizers publish (tickets sell only once
  # verified); elsewhere verification is still needed to publish.
  def ready_to_publish_free_events?
    (verification_status_verified? || self.class.verification_gate_enabled?) && policy_accepted?
  end

  def ready_to_publish_paid_events?
    ready_to_publish_free_events? && organization.payout_ready?
  end
end
