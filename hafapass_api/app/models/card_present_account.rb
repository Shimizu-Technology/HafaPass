# frozen_string_literal: true

class CardPresentAccount < ApplicationRecord
  PROVIDERS = %w[boh_clover].freeze

  belongs_to :organization
  belongs_to :verified_by_user, class_name: "User", optional: true
  has_many :card_present_payment_attempts, dependent: :restrict_with_error

  enum :status, { onboarding: 0, verified: 1, disabled: 2 }, prefix: true
  enum :connection_mode, { cloud: 0, local: 1 }, prefix: true

  validates :provider, inclusion: { in: PROVIDERS }
  validates :organization_id, uniqueness: true
  validates :merchant_id, :device_id, :pos_id, length: { maximum: 255 }, allow_blank: true
  validates :merchant_id, :device_id, :pos_id, presence: true, if: :status_verified?
  validate :verified_state_has_evidence

  def payment_ready?
    status_verified? && connection_mode_cloud? && merchant_id.present? && device_id.present? && pos_id.present? &&
      verification_evidence["guam_merchant_approved"] == true &&
      verification_evidence["verification_reference"].present?
  end

  private

  def verified_state_has_evidence
    return unless status_verified?
    reference = verification_evidence["verification_reference"].to_s
    return if verified_at.present? && verified_by_user.present? && verification_evidence["guam_merchant_approved"] == true &&
      reference.present? && reference.length <= 255

    errors.add(:base, "Verified Guam merchant evidence, reference, and reviewer are required")
  end
end
