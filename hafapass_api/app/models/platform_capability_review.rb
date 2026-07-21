# frozen_string_literal: true

class PlatformCapabilityReview < ApplicationRecord
  belongs_to :parent_review, class_name: "PlatformCapabilityReview", optional: true
  belongs_to :actor_user, class_name: "User"
  has_many :child_reviews, class_name: "PlatformCapabilityReview", foreign_key: :parent_review_id,
    dependent: :restrict_with_error, inverse_of: :parent_review

  enum :decision, { submission: 0, approval: 1, revocation: 2, rejection: 3 }, prefix: true

  validates :capability, inclusion: { in: PlatformCapabilities.names }
  validates :evidence_reference, :effective_at, :expires_at, :configuration_digest, presence: true
  validates :evidence_digest, :configuration_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validate :complete_control_snapshot
  validate :valid_parent_relationship
  validate :independent_approver
  validate :parent_snapshot_matches
  validate :reason_present_for_negative_decision
  validate :valid_effective_window

  attr_readonly :parent_review_id, :actor_user_id, :capability, :decision, :evidence_reference,
    :evidence_digest, :configuration_digest, :controls, :effective_at, :expires_at, :reason

  before_update :prevent_mutation
  before_destroy :prevent_mutation

  scope :approvals, -> { where(decision: :approval) }
  scope :revocations, -> { where(decision: :revocation) }

  def active?(at: Time.current)
    decision_approval? && effective_at <= at && expires_at > at && !revoked? && configuration_unchanged?
  end

  def revoked?
    child_reviews.decision_revocation.exists?
  end

  private

  def complete_control_snapshot
    normalized = controls.to_h.stringify_keys
    missing = PlatformCapabilities.required_controls(capability).reject { |key| normalized[key] == true }
    errors.add(:controls, "must affirm: #{missing.join(', ')}") if missing.any?
  end

  def valid_parent_relationship
    if decision_submission?
      errors.add(:parent_review, "must be absent for a submission") if parent_review
      return
    end

    if parent_review.nil?
      errors.add(:parent_review, "is required")
    elsif (decision_approval? || decision_rejection?) && !parent_review.decision_submission?
      errors.add(:parent_review, "must be a submission")
    elsif decision_revocation? && !parent_review.decision_approval?
      errors.add(:parent_review, "must be an approval")
    elsif parent_review.capability != capability
      errors.add(:parent_review, "must belong to the same capability")
    end
  end

  def independent_approver
    return unless decision_approval? && parent_review && actor_user_id == parent_review.actor_user_id

    errors.add(:actor_user, "must be independent from the evidence submitter")
  end

  def parent_snapshot_matches
    return unless parent_review

    fields = %w[capability evidence_reference evidence_digest configuration_digest controls effective_at expires_at]
    unless fields.all? { |field| public_send(field) == parent_review.public_send(field) }
      errors.add(:base, "Evidence snapshot must match the parent review")
    end
  end

  def reason_present_for_negative_decision
    return unless (decision_revocation? || decision_rejection?) && reason.to_s.strip.blank?

    errors.add(:reason, "is required for a revocation or rejection")
  end

  def valid_effective_window
    return if effective_at.blank? || expires_at.blank?

    errors.add(:expires_at, "must be after the effective time") unless expires_at > effective_at
  end

  def configuration_unchanged?
    configuration_digest == PlatformCapabilities.configuration_digest(capability)
  end

  def prevent_mutation
    errors.add(:base, "Platform capability evidence is append-only")
    throw(:abort)
  end
end
