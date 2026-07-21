# frozen_string_literal: true

class PilotValidationReview < ApplicationRecord
  DEVICE_TARGETS = {
    "ios_safari" => { required: true, physical: true },
    "android_chrome" => { required: true, physical: true },
    "desktop_chrome" => { required: true, physical: false },
    "desktop_safari" => { required: false, physical: false },
    "desktop_firefox" => { required: false, physical: false },
    "desktop_edge" => { required: false, physical: false }
  }.freeze
  DEVICE_FIELDS = %w[
    status device_name os_version browser_version tester_reference evidence_reference physical_device unavailable_reason
  ].freeze
  BUYER_FLOW_KEYS = %w[
    guest_browse_and_checkout authenticated_checkout payment_return_and_recovery refund transfer
    wallet_or_documented_not_launching reminder waitlist add_on assigned_seat_or_not_applicable
    ticket_presentation low_connectivity recovery_after_browser_loss
  ].freeze
  ORGANIZER_FLOW_KEYS = %w[
    role_boundaries event_lifecycle finance communications seating_or_not_applicable box_office support admin_boundaries
  ].freeze
  ACCESSIBILITY_CHECK_KEYS = %w[
    keyboard_only focus_and_dialogs errors_and_status_announcements zoom_and_reflow reduced_motion
    equivalent_accessible_seat_discovery equivalent_accessible_seat_purchase no_medical_proof_request
  ].freeze
  ASSISTIVE_TECHNOLOGY_TARGETS = %w[ios_voiceover android_talkback desktop_screen_reader].freeze
  ASSISTIVE_TECHNOLOGY_FIELDS = %w[status platform technology_version tester_reference evidence_reference].freeze
  ACCESSIBILITY_REVIEWER_FIELDS = %w[name qualification_reference evidence_reference].freeze
  LOAD_RESULT_FIELDS = %w[
    scenario_name tool_name target_environment expected_concurrent_buyers executed_concurrent_buyers
    request_count duration_seconds p95_latency_ms latency_budget_ms observed_error_rate_percent
    error_rate_budget_percent peak_database_connections database_connection_limit inventory_contention_attempts
    seat_contention_attempts expired_holds_expected expired_holds_observed oversell_count duplicate_sale_count
    all_holds_reconciled
  ].freeze
  CONTROL_KEYS = %w[
    privacy_safe_artifacts representative_buyers_completed venue_staff_completed findings_triaged
    all_findings_resolved no_open_p0_or_p1
  ].freeze

  belongs_to :event
  belongs_to :pilot_readiness_review
  belongs_to :parent_review, class_name: "PilotValidationReview", optional: true
  belongs_to :actor_user, class_name: "User"
  has_many :child_reviews, class_name: "PilotValidationReview", foreign_key: :parent_review_id,
    dependent: :restrict_with_error, inverse_of: :parent_review

  enum :decision, { submission: 0, approval: 1, revocation: 2, rejection: 3 }, prefix: true

  validates :evidence_reference, :evidence_digest, :event_state_digest, :application_revision,
    :effective_at, :expires_at, presence: true
  validates :evidence_digest, :event_state_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validate :complete_device_matrix
  validate :complete_flow_matrices
  validate :complete_accessibility_results
  validate :valid_load_results
  validate :complete_controls
  validate :valid_readiness_relationship
  validate :valid_parent_relationship
  validate :independent_approver
  validate :parent_snapshot_matches
  validate :reason_present_for_negative_decision
  validate :valid_effective_window

  attr_readonly :event_id, :pilot_readiness_review_id, :parent_review_id, :actor_user_id, :decision,
    :evidence_reference, :evidence_digest, :event_state_digest, :application_revision, :device_matrix,
    :buyer_flows, :organizer_flows, :accessibility_results, :load_results, :controls, :effective_at,
    :expires_at, :reason

  before_update :prevent_mutation
  before_destroy :prevent_mutation

  scope :approvals, -> { where(decision: :approval) }
  scope :revocations, -> { where(decision: :revocation) }

  def active?(at: Time.current)
    decision_approval? && effective_at <= at && expires_at > at && !revoked? && candidate_current?(at: at)
  end

  def revoked?
    child_reviews.decision_revocation.exists?
  end

  private

  def complete_device_matrix
    normalized = device_matrix.to_h.stringify_keys
    DEVICE_TARGETS.each do |target, requirements|
      result = normalized[target].to_h.stringify_keys
      status = result["status"].to_s
      if requirements[:required] && status != "passed"
        errors.add(:device_matrix, "must pass #{target}")
      elsif !%w[passed unavailable].include?(status)
        errors.add(:device_matrix, "must record passed or unavailable for #{target}")
      end

      if status == "passed"
        %w[device_name os_version browser_version tester_reference evidence_reference].each do |field|
          errors.add(:device_matrix, "must include #{target}.#{field}") if result[field].to_s.strip.blank?
        end
        if requirements[:physical] && !ActiveModel::Type::Boolean.new.cast(result["physical_device"])
          errors.add(:device_matrix, "must use a physical device for #{target}")
        end
      elsif status == "unavailable" && result["unavailable_reason"].to_s.strip.blank?
        errors.add(:device_matrix, "must explain why #{target} is unavailable")
      end
    end
  end

  def complete_flow_matrices
    validate_boolean_matrix(:buyer_flows, buyer_flows, BUYER_FLOW_KEYS)
    validate_boolean_matrix(:organizer_flows, organizer_flows, ORGANIZER_FLOW_KEYS)
  end

  def complete_accessibility_results
    normalized = accessibility_results.to_h.stringify_keys
    validate_boolean_matrix(:accessibility_results, normalized["checks"], ACCESSIBILITY_CHECK_KEYS)

    assistive = normalized["assistive_technology"].to_h.stringify_keys
    ASSISTIVE_TECHNOLOGY_TARGETS.each do |target|
      result = assistive[target].to_h.stringify_keys
      errors.add(:accessibility_results, "must pass #{target}") unless result["status"] == "passed"
      %w[platform technology_version tester_reference evidence_reference].each do |field|
        errors.add(:accessibility_results, "must include #{target}.#{field}") if result[field].to_s.strip.blank?
      end
    end

    reviewer = normalized["reviewer"].to_h.stringify_keys
    ACCESSIBILITY_REVIEWER_FIELDS.each do |field|
      errors.add(:accessibility_results, "must include reviewer.#{field}") if reviewer[field].to_s.strip.blank?
    end
  end

  def valid_load_results
    normalized = load_results.to_h.stringify_keys
    %w[scenario_name tool_name target_environment].each do |field|
      errors.add(:load_results, "must include #{field}") if normalized[field].to_s.strip.blank?
    end

    integers = %w[
      expected_concurrent_buyers executed_concurrent_buyers request_count duration_seconds p95_latency_ms
      latency_budget_ms peak_database_connections database_connection_limit inventory_contention_attempts
      seat_contention_attempts expired_holds_expected expired_holds_observed oversell_count duplicate_sale_count
    ].index_with { |field| integer_value(normalized[field], field) }
    decimals = %w[observed_error_rate_percent error_rate_budget_percent]
      .index_with { |field| decimal_value(normalized[field], field) }
    return if errors[:load_results].any?

    %w[
      expected_concurrent_buyers executed_concurrent_buyers request_count duration_seconds p95_latency_ms
      latency_budget_ms database_connection_limit inventory_contention_attempts
    ].each do |field|
      errors.add(:load_results, "#{field} must be greater than zero") unless integers[field].positive?
    end
    if integers["executed_concurrent_buyers"] < integers["expected_concurrent_buyers"]
      errors.add(:load_results, "executed concurrency must meet or exceed the expected onsale")
    end
    if integers["p95_latency_ms"] > integers["latency_budget_ms"]
      errors.add(:load_results, "p95 latency exceeds the declared budget")
    end
    if integers["latency_budget_ms"] > 1500
      errors.add(:load_results, "p95 latency budget cannot exceed 1500 ms for the pilot")
    end
    if decimals["observed_error_rate_percent"].negative? || decimals["error_rate_budget_percent"].negative? ||
        decimals["observed_error_rate_percent"] > decimals["error_rate_budget_percent"]
      errors.add(:load_results, "observed error rate exceeds the declared budget")
    end
    if decimals["error_rate_budget_percent"] > 1
      errors.add(:load_results, "error-rate budget cannot exceed 1 percent for the pilot")
    end
    if integers["peak_database_connections"].negative? ||
        integers["peak_database_connections"] >= integers["database_connection_limit"]
      errors.add(:load_results, "peak database connections must remain below the configured limit")
    end
    if integers["expired_holds_expected"] != integers["expired_holds_observed"]
      errors.add(:load_results, "expired hold observations must match the expected count")
    end
    if integers["oversell_count"] != 0 || integers["duplicate_sale_count"] != 0
      errors.add(:load_results, "must prove zero oversells and duplicate sales")
    end
    unless ActiveModel::Type::Boolean.new.cast(normalized["all_holds_reconciled"])
      errors.add(:load_results, "must confirm every load-test hold reached a known final state")
    end
    if event&.assigned_seating? && !integers["seat_contention_attempts"].positive?
      errors.add(:load_results, "must include assigned-seat contention attempts")
    end
  end

  def complete_controls
    validate_boolean_matrix(:controls, controls, CONTROL_KEYS)
  end

  def validate_boolean_matrix(attribute, matrix, keys)
    normalized = matrix.to_h.stringify_keys
    missing = keys.reject { |key| normalized[key] == true }
    errors.add(attribute, "must affirm: #{missing.join(', ')}") if missing.any?
  end

  def integer_value(value, field)
    Integer(value, exception: true)
  rescue ArgumentError, TypeError
    errors.add(:load_results, "#{field} must be an integer")
    0
  end

  def decimal_value(value, field)
    BigDecimal(value.to_s)
  rescue ArgumentError
    errors.add(:load_results, "#{field} must be numeric")
    0.to_d
  end

  def valid_readiness_relationship
    return if pilot_readiness_review.nil?

    unless pilot_readiness_review.event_id == event_id && pilot_readiness_review.decision_approval?
      errors.add(:pilot_readiness_review, "must be an approval for the same event")
    end
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

    errors.add(:actor_user, "must be independent from the validation submitter")
  end

  def parent_snapshot_matches
    return unless parent_review

    fields = %w[
      pilot_readiness_review_id evidence_reference evidence_digest event_state_digest application_revision
      device_matrix buyer_flows organizer_flows accessibility_results load_results controls effective_at expires_at
    ]
    unless fields.all? { |field| public_send(field) == parent_review.public_send(field) }
      errors.add(:base, "Validation snapshot must match the parent review")
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

  def candidate_current?(at:)
    return false unless application_revision == PilotReadiness.application_revision
    state_digest = PilotReadiness.event_state_digest(event)
    return false unless event_state_digest == state_digest

    PilotReadiness.active_approval(event, at: at, state_digest: state_digest)&.id == pilot_readiness_review_id
  end

  def prevent_mutation
    errors.add(:base, "Pilot validation evidence is append-only")
    throw(:abort)
  end
end
