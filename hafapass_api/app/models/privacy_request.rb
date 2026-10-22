# frozen_string_literal: true

class PrivacyRequest < ApplicationRecord
  KINDS = %w[access deletion].freeze
  STATUSES = %w[submitted verified completed partially_completed blocked].freeze

  belongs_to :user, optional: true
  belongs_to :order, optional: true
  belongs_to :verified_by, class_name: "User", optional: true
  belongs_to :executed_by, class_name: "User", optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :requester_email, presence: true
  validate :subject_present

  def verified?
    verified_at.present? && (user_id.present? || guest_challenge_passed_at.present?)
  end

  def issue_guest_challenge!
    raise ArgumentError, "Only guest requests need an email challenge" if user_id.present?

    code = SecureRandom.random_number(1_000_000).to_s.rjust(6, "0")
    update!(guest_challenge_digest: Digest::SHA256.hexdigest(code),
      guest_challenge_expires_at: 15.minutes.from_now, guest_challenge_attempts: 0)
    code
  end

  def verify_guest_challenge!(code)
    with_lock do
      return false if user_id.present? || verified_at.present? || guest_challenge_digest.blank? ||
        guest_challenge_expires_at.blank? || guest_challenge_expires_at.past? || guest_challenge_attempts >= 5

      update!(guest_challenge_attempts: guest_challenge_attempts + 1)
      match = ActiveSupport::SecurityUtils.secure_compare(guest_challenge_digest,
        Digest::SHA256.hexdigest(code.to_s))
      update!(status: "verified", verified_at: Time.current, guest_challenge_digest: nil,
        guest_challenge_expires_at: nil, guest_challenge_passed_at: Time.current) if match
      match
    end
  end

  private

  def subject_present
    errors.add(:base, "An account or verified guest order is required") unless user_id || order_id
  end
end
