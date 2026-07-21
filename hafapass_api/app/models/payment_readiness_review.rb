# frozen_string_literal: true

class PaymentReadinessReview < ApplicationRecord
  CONTROL_KEYS = %w[
    guam_territory_confirmed platform_entity_model_confirmed organizer_onboarding_confirmed
    charges_confirmed payouts_confirmed refunds_disputes_confirmed bank_account_confirmed
    fee_tax_schedule_approved liability_schedule_approved
  ].freeze
  MERCHANTS_OF_RECORD = %w[platform organizer provider_managed].freeze

  belongs_to :connected_account
  belongs_to :parent_review, class_name: "PaymentReadinessReview", optional: true
  belongs_to :actor_user, class_name: "User"
  has_many :child_reviews, class_name: "PaymentReadinessReview", foreign_key: :parent_review_id,
    dependent: :restrict_with_error, inverse_of: :parent_review

  enum :decision, { submission: 0, approval: 1, revocation: 2, rejection: 3 }, prefix: true

  validates :evidence_reference, :provider_approval_reference, :fee_tax_schedule_reference,
    :liability_schedule_reference, :effective_at, :expires_at, :provider_state_digest, presence: true
  validates :evidence_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :provider_state_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :merchant_of_record, inclusion: { in: MERCHANTS_OF_RECORD }
  validate :complete_control_snapshot
  validate :valid_parent_relationship
  validate :independent_approver
  validate :parent_snapshot_matches
  validate :revocation_reason_present
  validate :valid_effective_window

  attr_readonly :connected_account_id, :parent_review_id, :actor_user_id, :decision,
    :evidence_reference, :evidence_digest, :provider_approval_reference, :merchant_of_record,
    :fee_tax_schedule_reference, :liability_schedule_reference, :controls, :effective_at,
    :expires_at, :provider_state_digest, :reason

  before_update :prevent_mutation
  before_destroy :prevent_mutation

  scope :approvals, -> { where(decision: :approval) }
  scope :revocations, -> { where(decision: :revocation) }

  def active?(at: Time.current)
    decision_approval? && effective_at <= at && expires_at > at && !revoked? && provider_state_unchanged?
  end

  def revoked?
    child_reviews.decision_revocation.exists?
  end

  private

  def complete_control_snapshot
    normalized = controls.to_h.stringify_keys
    missing = CONTROL_KEYS.reject { |key| normalized[key] == true }
    errors.add(:controls, "must affirm: #{missing.join(', ')}") if missing.any?
  end

  def valid_parent_relationship
    if decision_submission?
      errors.add(:parent_review, "must be absent for a submission") if parent_review
      return
    end

    if parent_review.nil?
      errors.add(:parent_review, "is required")
    elsif decision_approval? && !parent_review.decision_submission?
      errors.add(:parent_review, "must be a submission")
    elsif decision_revocation? && !parent_review.decision_approval?
      errors.add(:parent_review, "must be an approval")
    elsif decision_rejection? && !parent_review.decision_submission?
      errors.add(:parent_review, "must be a submission")
    elsif parent_review.connected_account_id != connected_account_id
      errors.add(:parent_review, "must belong to the same connected account")
    end
  end

  def valid_effective_window
    return if effective_at.blank? || expires_at.blank?

    errors.add(:expires_at, "must be after the effective time") unless expires_at > effective_at
  end

  def independent_approver
    return unless decision_approval? && parent_review && actor_user_id == parent_review.actor_user_id

    errors.add(:actor_user, "must be independent from the evidence submitter")
  end

  def parent_snapshot_matches
    return unless parent_review

    fields = %w[
      evidence_reference evidence_digest provider_approval_reference merchant_of_record
      fee_tax_schedule_reference liability_schedule_reference controls effective_at expires_at
      provider_state_digest
    ]
    errors.add(:base, "Evidence snapshot must match the parent review") unless fields.all? do |field|
      public_send(field) == parent_review.public_send(field)
    end
  end

  def revocation_reason_present
    return unless (decision_revocation? || decision_rejection?) && reason.to_s.strip.blank?

    errors.add(:reason, "is required for a revocation or rejection")
  end

  def provider_state_unchanged?
    provider_state_digest == connected_account.readiness_state_digest
  end

  def prevent_mutation
    errors.add(:base, "Payment readiness evidence is append-only")
    throw(:abort)
  end
end
