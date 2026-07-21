# frozen_string_literal: true

class PilotReadinessReview < ApplicationRecord
  CONTROL_KEYS = %w[
    low_risk_scope organizer_identity_and_agreement payout_method event_content_and_prohibited_review
    venue_schedule_capacity_inventory pricing_fees_and_refund_policy seating_physically_reconciled_or_not_applicable
    support_channels_and_sla cash_controls_and_staffing scanners_spares_and_connectivity
    emergency_door_list_restricted no_open_p0_or_p1
  ].freeze
  ASSIGNMENT_KEYS = %w[
    primary_on_call backup_on_call event_commander door_lead finance_contact venue_safety_contact
  ].freeze
  ASSIGNMENT_FIELDS = %w[name contact_reference].freeze

  belongs_to :event
  belongs_to :parent_review, class_name: "PilotReadinessReview", optional: true
  belongs_to :actor_user, class_name: "User"
  has_many :child_reviews, class_name: "PilotReadinessReview", foreign_key: :parent_review_id,
    dependent: :restrict_with_error, inverse_of: :parent_review

  enum :decision, { submission: 0, approval: 1, revocation: 2, rejection: 3 }, prefix: true

  validates :evidence_reference, :evidence_digest, :event_state_digest, :application_revision,
    :effective_at, :expires_at, presence: true
  validates :evidence_digest, :event_state_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validate :complete_control_snapshot
  validate :complete_assignments
  validate :valid_parent_relationship
  validate :independent_approver
  validate :parent_snapshot_matches
  validate :reason_present_for_negative_decision
  validate :valid_effective_window

  attr_readonly :event_id, :parent_review_id, :actor_user_id, :decision, :evidence_reference,
    :evidence_digest, :event_state_digest, :application_revision, :controls, :assignments,
    :effective_at, :expires_at, :reason

  before_update :prevent_mutation
  before_destroy :prevent_mutation

  scope :approvals, -> { where(decision: :approval) }
  scope :revocations, -> { where(decision: :revocation) }

  def active?(at: Time.current)
    decision_approval? && effective_at <= at && expires_at > at && !revoked? && event_state_unchanged?
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

  def complete_assignments
    normalized = assignments.to_h.stringify_keys
    missing = ASSIGNMENT_KEYS.flat_map do |role|
      assignment = normalized[role].to_h.stringify_keys
      ASSIGNMENT_FIELDS.filter_map { |field| "#{role}.#{field}" if assignment[field].to_s.strip.blank? }
    end
    errors.add(:assignments, "must include: #{missing.join(', ')}") if missing.any?
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
    elsif parent_review.event_id != event_id
      errors.add(:parent_review, "must belong to the same event")
    end
  end

  def independent_approver
    return unless decision_approval? && parent_review && actor_user_id == parent_review.actor_user_id

    errors.add(:actor_user, "must be independent from the readiness submitter")
  end

  def parent_snapshot_matches
    return unless parent_review

    fields = %w[
      evidence_reference evidence_digest event_state_digest application_revision controls assignments effective_at expires_at
    ]
    unless fields.all? { |field| public_send(field) == parent_review.public_send(field) }
      errors.add(:base, "Readiness snapshot must match the parent review")
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

  def event_state_unchanged?
    event_state_digest == PilotReadiness.event_state_digest(event)
  end

  def prevent_mutation
    errors.add(:base, "Pilot readiness evidence is append-only")
    throw(:abort)
  end
end
