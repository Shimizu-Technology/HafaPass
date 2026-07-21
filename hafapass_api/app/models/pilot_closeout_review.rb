# frozen_string_literal: true

class PilotCloseoutReview < ApplicationRecord
  include AppendOnlyRecord

  OUTCOME_INTEGER_FIELDS = %w[
    support_contacts_count entry_latency_p50_ms entry_latency_p95_ms organizer_feedback_rating
    buyer_feedback_response_count buyer_feedback_rating
  ].freeze
  RECONCILIATION_FIELDS = %w[
    sales discounts taxes fees refunds disputes add_ons door_sales settlement payout scans support_cases
    message_exceptions admission_exceptions reconciliation_exceptions
  ].freeze
  CLEANUP_FIELDS = %w[
    temporary_staff_revoked scanner_devices_revoked device_local_data_purged retention_policy_followed
  ].freeze
  EVIDENCE_REFERENCE_FIELDS = %w[
    financial provider admission support cleanup metrics feedback retrospective
  ].freeze
  RETROSPECTIVE_STATUSES = %w[completed planned].freeze
  RETROSPECTIVE_PRIORITIES = %w[p0 p1 p2 p3].freeze
  PRODUCT_INVESTMENTS = %w[complex_charts waiting_room memberships_season_products].freeze
  SNAPSHOT_FIELDS = %w[
    event_id live_pilot_run_id expansion_decision evidence_reference evidence_digest local_state_digest
    application_revision local_metrics outcome_metrics reconciliation_results cleanup_results evidence_references
    retrospective_actions expansion_scope
  ].freeze

  belongs_to :event
  belongs_to :live_pilot_run
  belongs_to :parent_review, class_name: "PilotCloseoutReview", optional: true
  belongs_to :actor_user, class_name: "User"
  has_many :child_reviews, class_name: "PilotCloseoutReview", foreign_key: :parent_review_id,
    dependent: :restrict_with_error, inverse_of: :parent_review

  enum :decision, { submission: 0, approval: 1, revocation: 2, rejection: 3 }, prefix: true
  enum :expansion_decision, { hold: 0, repeat_bounded_pilot: 1, limited_guam_expansion: 2 },
    prefix: true

  validates :evidence_reference, :application_revision, :signed_at, presence: true
  validates :evidence_digest, :local_state_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validate :relationships_match
  validate :parent_matches_decision
  validate :independent_approver
  validate :parent_snapshot_matches
  validate :negative_reason_present
  validate :outcome_metrics_complete
  validate :attestations_complete
  validate :evidence_references_complete
  validate :retrospective_actions_complete
  validate :expansion_scope_complete

  def revoked?
    child_reviews.decision_revocation.exists?
  end

  def expansion_current?(at: Time.current)
    return true if expansion_decision_hold?

    Time.iso8601(expansion_scope.to_h.stringify_keys["expires_at"].to_s) > at
  rescue ArgumentError
    false
  end

  private

  def relationships_match
    return unless event && live_pilot_run

    errors.add(:live_pilot_run, "must be the completed Gate I run for the same event") unless
      live_pilot_run.event_id == event_id && live_pilot_run.status_completed?
  end

  def parent_matches_decision
    if decision_submission? && parent_review.present?
      errors.add(:parent_review, "must be blank for a submission")
    elsif !decision_submission? && parent_review.nil?
      errors.add(:parent_review, "is required for a decision")
    elsif parent_review && parent_review.live_pilot_run_id != live_pilot_run_id
      errors.add(:parent_review, "must concern the same Gate I run")
    elsif (decision_approval? || decision_rejection?) && !parent_review&.decision_submission?
      errors.add(:parent_review, "must be a Gate J submission")
    elsif decision_revocation? && !parent_review&.decision_approval?
      errors.add(:parent_review, "must be a Gate J approval")
    end
  end

  def independent_approver
    return unless decision_approval? && parent_review

    errors.add(:actor_user, "must differ from the closeout submitter") if actor_user_id == parent_review.actor_user_id
  end

  def parent_snapshot_matches
    return unless parent_review

    differences = SNAPSHOT_FIELDS.reject do |field|
      public_send(field) == parent_review.public_send(field)
    end
    errors.add(:base, "Closeout decisions must preserve the submitted snapshot") if differences.any?
  end

  def negative_reason_present
    return unless (decision_rejection? || decision_revocation?) && reason.to_s.strip.blank?

    errors.add(:reason, "is required for rejection or revocation")
  end

  def outcome_metrics_complete
    values = outcome_metrics.to_h.stringify_keys
    missing = OUTCOME_INTEGER_FIELDS.reject { |field| values[field].is_a?(Integer) }
    errors.add(:outcome_metrics, "must include integer values for: #{missing.join(', ')}") if missing.any?
    return if missing.any?

    nonnegative = OUTCOME_INTEGER_FIELDS.all? { |field| values[field] >= 0 }
    errors.add(:outcome_metrics, "counts and latency must be non-negative") unless nonnegative
    if values["entry_latency_p95_ms"] < values["entry_latency_p50_ms"]
      errors.add(:outcome_metrics, "entry p95 cannot be lower than p50")
    end
    unless values["organizer_feedback_rating"].between?(1, 5)
      errors.add(:outcome_metrics, "organizer feedback must be between 1 and 5")
    end
    buyer_valid = if values["buyer_feedback_response_count"].zero?
      values["buyer_feedback_rating"].zero?
    else
      values["buyer_feedback_rating"].between?(1, 5)
    end
    errors.add(:outcome_metrics, "buyer feedback must be zero with no responses or between 1 and 5") unless buyer_valid
  end

  def attestations_complete
    validate_true_fields(reconciliation_results, RECONCILIATION_FIELDS, :reconciliation_results)
    validate_true_fields(cleanup_results, CLEANUP_FIELDS, :cleanup_results)
  end

  def validate_true_fields(value, fields, attribute)
    results = value.to_h.stringify_keys
    missing = fields.reject { |field| results[field] == true }
    errors.add(attribute, "must affirm: #{missing.join(', ')}") if missing.any?
  end

  def evidence_references_complete
    references = evidence_references.to_h.stringify_keys
    missing = EVIDENCE_REFERENCE_FIELDS.reject { |field| references[field].to_s.strip.present? }
    errors.add(:evidence_references, "must include: #{missing.join(', ')}") if missing.any?
  end

  def retrospective_actions_complete
    actions = retrospective_actions
    unless actions.is_a?(Array) && actions.length.between?(1, 25)
      errors.add(:retrospective_actions, "must contain between 1 and 25 actions")
      return
    end

    actions.each_with_index do |raw, index|
      action = raw.to_h.stringify_keys
      required = %w[title owner_reference due_at status priority evidence_reference]
      missing = required.reject { |field| action[field].to_s.strip.present? }
      errors.add(:retrospective_actions, "action #{index + 1} is missing #{missing.join(', ')}") if missing.any?
      unless RETROSPECTIVE_STATUSES.include?(action["status"])
        errors.add(:retrospective_actions, "action #{index + 1} has an invalid status")
      end
      unless RETROSPECTIVE_PRIORITIES.include?(action["priority"])
        errors.add(:retrospective_actions, "action #{index + 1} has an invalid priority")
      end
      begin
        due_at = Time.iso8601(action["due_at"].to_s)
        if decision_submission? && action["status"] == "planned" && signed_at && due_at <= signed_at
          errors.add(:retrospective_actions, "action #{index + 1} planned due_at must be after signing")
        end
      rescue ArgumentError
        errors.add(:retrospective_actions, "action #{index + 1} due_at must be ISO-8601")
      end
      unless action["blocks_expansion"] == true || action["blocks_expansion"] == false
        errors.add(:retrospective_actions, "action #{index + 1} must state whether it blocks expansion")
      end
    end
  end

  def expansion_scope_complete
    scope = expansion_scope.to_h.stringify_keys
    event_limit = scope["event_limit"]
    inventory_cap = scope["max_inventory_per_event"]
    unless event_limit.is_a?(Integer) && inventory_cap.is_a?(Integer)
      errors.add(:expansion_scope, "must include integer event and inventory limits")
      return
    end
    errors.add(:expansion_scope, "requires a decision rationale") if scope["rationale"].to_s.strip.blank?
    errors.add(:expansion_scope, "cannot authorize new regions from the Guam pilot") unless scope["new_regions"] == false

    investments = Array(scope["recommended_product_investments"])
    invalid = investments - PRODUCT_INVESTMENTS
    errors.add(:expansion_scope, "contains unsupported product investments: #{invalid.join(', ')}") if invalid.any?
    if investments.any? && scope["product_evidence_reference"].to_s.strip.blank?
      errors.add(:expansion_scope, "requires product evidence for recommended investments")
    end

    if expansion_decision_hold?
      errors.add(:expansion_scope, "hold decisions must authorize zero events and inventory") unless
        event_limit.zero? && inventory_cap.zero? && scope["expires_at"].blank?
    elsif expansion_decision_repeat_bounded_pilot?
      errors.add(:expansion_scope, "repeat pilots must authorize one event and at most 250 tickets") unless
        event_limit == 1 && inventory_cap.between?(1, 250)
      validate_expansion_window(scope)
    elsif expansion_decision_limited_guam_expansion?
      errors.add(:expansion_scope, "limited Guam expansion must authorize 1–10 events and at most 1,000 tickets") unless
        event_limit.between?(1, 10) && inventory_cap.between?(1, 1000)
      %w[demand_evidence_reference capacity_evidence_reference].each do |field|
        errors.add(:expansion_scope, "requires #{field.humanize.downcase}") if scope[field].to_s.strip.blank?
      end
      validate_expansion_window(scope)
    end
  end

  def validate_expansion_window(scope)
    expires_at = Time.iso8601(scope["expires_at"].to_s)
    if decision_submission? && !(expires_at > signed_at && expires_at <= signed_at + 90.days)
      errors.add(:expansion_scope, "must expire after signing and within 90 days")
    elsif decision_approval? && expires_at <= signed_at
      errors.add(:expansion_scope, "expired before independent approval")
    end
  rescue ArgumentError
    errors.add(:expansion_scope, "expires_at must be ISO-8601")
  end
end
