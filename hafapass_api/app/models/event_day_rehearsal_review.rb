# frozen_string_literal: true

require "time"

class EventDayRehearsalReview < ApplicationRecord
  MINIMUM_PHYSICAL_DEVICES = 3
  MANIFEST_FIELDS = %w[
    rehearsal_event_reference version digest key_id algorithm ticket_count generated_at expires_at
    signed_manifest_evidence_reference emergency_door_list_reference emergency_door_list_digest
    signature_verified_on_every_device
  ].freeze
  DEVICE_FIELDS = %w[
    identifier name model os_version browser browser_version tester_reference evidence_reference physical_device
    manifest_signature_verified offline_mode_completed reconnect_order queued_actions_before_sync
    queued_actions_after_sync conflicts_observed immediate_feedback_p95_ms battery_plan_reference
    spare_device_reference
  ].freeze
  SCAN_KEYS = %w[
    valid_unique invalid_credential same_ticket_cross_device duplicate refunded transferred rotated
    payment_blocked already_admitted manual_lookup authorized_reversal reconnect_in_different_order
    conflict_resolution queue_drain
  ].freeze
  INCIDENT_KEYS = %w[
    payment_provider_outage venue_network_loss worker_failure severe_application_error evacuation_sales_pause
    refund_incident support_escalation
  ].freeze
  INCIDENT_FIELDS = %w[status evidence_reference alert_acknowledgement_reference resolution_reference].freeze
  DOOR_CHANNELS = %w[cash card_present].freeze
  DOOR_SALE_FIELDS = %w[
    status evidence_reference reconciliation_reference disabled_reason provider account_readiness_reference
    successful_attempt_reference unknown_outcome_reference no_blind_retry_confirmed
  ].freeze
  RECONCILIATION_FIELDS = %w[
    generated_ticket_count unique_admissions_expected unique_admissions_observed duplicate_conflicts_expected
    duplicate_conflicts_observed pending_queue_count unresolved_conflict_count unexplained_admission_variance
    unexplained_inventory_variance unexplained_cash_variance_cents unexplained_card_variance_cents
    online_scan_p95_ms offline_feedback_p95_ms all_card_attempts_resolved all_devices_synced
  ].freeze
  ASSIGNMENT_KEYS = %w[
    event_commander technical_lead door_lead finance_contact venue_safety_contact support_escalation_owner
  ].freeze
  ASSIGNMENT_FIELDS = %w[name private_contact_reference acknowledgement_reference].freeze
  CONTROL_KEYS = %w[
    stable_signing_key_confirmed emergency_list_handling_confirmed spare_devices_and_batteries_confirmed
    venue_network_fallback_confirmed cash_control_approved card_present_policy_approved alerts_acknowledged
    rehearsal_log_complete all_findings_resolved no_open_p0_or_p1 explicit_go_decision
  ].freeze

  belongs_to :event
  belongs_to :pilot_validation_review
  belongs_to :parent_review, class_name: "EventDayRehearsalReview", optional: true
  belongs_to :actor_user, class_name: "User"
  has_many :child_reviews, class_name: "EventDayRehearsalReview", foreign_key: :parent_review_id,
    dependent: :restrict_with_error, inverse_of: :parent_review

  enum :decision, { submission: 0, approval: 1, revocation: 2, rejection: 3 }, prefix: true

  validates :evidence_reference, :evidence_digest, :event_state_digest, :application_revision,
    :effective_at, :expires_at, presence: true
  validates :evidence_digest, :event_state_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validate :complete_manifest_results
  validate :complete_device_results
  validate :complete_scan_results
  validate :complete_incident_drills
  validate :complete_door_sales_results
  validate :valid_reconciliation_results
  validate :complete_assignments
  validate :complete_controls
  validate :valid_validation_relationship
  validate :valid_parent_relationship
  validate :independent_approver
  validate :parent_snapshot_matches
  validate :reason_present_for_negative_decision
  validate :valid_effective_window

  attr_readonly :event_id, :pilot_validation_review_id, :parent_review_id, :actor_user_id, :decision,
    :evidence_reference, :evidence_digest, :event_state_digest, :application_revision, :manifest_results,
    :device_results, :scan_results, :incident_drills, :door_sales_results, :reconciliation_results,
    :assignments, :controls, :effective_at, :expires_at, :reason

  before_update :prevent_mutation
  before_destroy :prevent_mutation

  scope :approvals, -> { where(decision: :approval) }
  scope :revocations, -> { where(decision: :revocation) }

  def revoked?
    child_reviews.decision_revocation.exists?
  end

  private

  def complete_manifest_results
    result = normalized_hash(manifest_results)
    MANIFEST_FIELDS.each do |field|
      errors.add(:manifest_results, "must include #{field}") if result[field].to_s.strip.blank?
    end
    errors.add(:manifest_results, "digest must be a SHA-256") unless sha256?(result["digest"])
    unless sha256?(result["emergency_door_list_digest"])
      errors.add(:manifest_results, "emergency door list digest must be a SHA-256")
    end
    unless ActiveModel::Type::Boolean.new.cast(result["signature_verified_on_every_device"])
      errors.add(:manifest_results, "must confirm signature verification on every device")
    end
    unless result["algorithm"] == "RSA-PSS-SHA256"
      errors.add(:manifest_results, "algorithm must be RSA-PSS-SHA256")
    end
    version = integer_value(result["version"], :manifest_results, "version")
    ticket_count = integer_value(result["ticket_count"], :manifest_results, "ticket_count")
    errors.add(:manifest_results, "version must be positive") if version && !version.positive?
    if ticket_count && ticket_count < 500
      errors.add(:manifest_results, "must contain at least 500 generated tickets")
    end
    generated_at = time_value(result["generated_at"], :manifest_results, "generated_at")
    expires_at = time_value(result["expires_at"], :manifest_results, "expires_at")
    if generated_at && expires_at && (expires_at <= generated_at || expires_at > generated_at + 24.hours)
      errors.add(:manifest_results, "expiry must be after generation and no more than 24 hours later")
    end
  end

  def complete_device_results
    results = device_results.is_a?(Array) ? device_results : []
    if results.length < MINIMUM_PHYSICAL_DEVICES
      errors.add(:device_results, "must include at least three physical devices")
      return
    end

    identifiers = results.map { |result| normalized_hash(result)["identifier"].to_s.strip }
    errors.add(:device_results, "must use distinct device identifiers") unless identifiers.reject(&:blank?).uniq.length == results.length
    reconnect_orders = []
    conflict_total = 0
    results.each_with_index do |raw_result, index|
      result = normalized_hash(raw_result)
      DEVICE_FIELDS.each do |field|
        errors.add(:device_results, "device #{index + 1} must include #{field}") if result[field].to_s.strip.blank?
      end
      %w[physical_device manifest_signature_verified offline_mode_completed].each do |field|
        unless ActiveModel::Type::Boolean.new.cast(result[field])
          errors.add(:device_results, "device #{index + 1} must confirm #{field}")
        end
      end
      reconnect_order = integer_value(result["reconnect_order"], :device_results, "reconnect_order")
      reconnect_orders << reconnect_order if reconnect_order
      queued_before = integer_value(result["queued_actions_before_sync"], :device_results, "queued_actions_before_sync")
      queued_after = integer_value(result["queued_actions_after_sync"], :device_results, "queued_actions_after_sync")
      conflicts = integer_value(result["conflicts_observed"], :device_results, "conflicts_observed")
      conflict_total += conflicts if conflicts
      p95 = integer_value(result["immediate_feedback_p95_ms"], :device_results, "immediate_feedback_p95_ms")
      if [queued_before, queued_after, conflicts, p95].compact.any?(&:negative?)
        errors.add(:device_results, "device counters and latency cannot be negative")
      end
      if queued_before && !queued_before.positive?
        errors.add(:device_results, "every device must queue offline actions")
      end
      if queued_after && !queued_after.zero?
        errors.add(:device_results, "every device queue must drain to zero")
      end
      if p95 && (!p95.positive? || p95 > 100)
        errors.add(:device_results, "offline feedback p95 must be positive and at most 100 ms")
      end
    end
    if reconnect_orders.length == results.length && reconnect_orders.sort != (1..results.length).to_a
      errors.add(:device_results, "reconnect order must uniquely cover every device")
    end
    if results.all? { |result| strict_integer(normalized_hash(result)["conflicts_observed"]) } && !conflict_total.positive?
      errors.add(:device_results, "must observe at least one cross-device conflict")
    end
  end

  def complete_scan_results
    validate_boolean_matrix(:scan_results, scan_results, SCAN_KEYS)
  end

  def complete_incident_drills
    normalized = normalized_hash(incident_drills)
    INCIDENT_KEYS.each do |key|
      result = normalized_hash(normalized[key])
      errors.add(:incident_drills, "must pass #{key}") unless result["status"] == "passed"
      INCIDENT_FIELDS.excluding("status").each do |field|
        errors.add(:incident_drills, "must include #{key}.#{field}") if result[field].to_s.strip.blank?
      end
    end
  end

  def complete_door_sales_results
    normalized = normalized_hash(door_sales_results)
    DOOR_CHANNELS.each do |channel|
      result = normalized_hash(normalized[channel])
      status = result["status"]
      unless %w[passed disabled].include?(status)
        errors.add(:door_sales_results, "must record passed or disabled for #{channel}")
        next
      end
      if status == "disabled"
        errors.add(:door_sales_results, "must explain why #{channel} is disabled") if result["disabled_reason"].to_s.strip.blank?
        if result["evidence_reference"].to_s.strip.blank?
          errors.add(:door_sales_results, "must include the signed #{channel} disablement decision reference")
        end
        next
      end
      %w[evidence_reference reconciliation_reference].each do |field|
        errors.add(:door_sales_results, "must include #{channel}.#{field}") if result[field].to_s.strip.blank?
      end
      next unless channel == "card_present"

      %w[provider account_readiness_reference successful_attempt_reference unknown_outcome_reference].each do |field|
        errors.add(:door_sales_results, "must include card_present.#{field}") if result[field].to_s.strip.blank?
      end
      unless ActiveModel::Type::Boolean.new.cast(result["no_blind_retry_confirmed"])
        errors.add(:door_sales_results, "must confirm unknown card outcomes were not retried blindly")
      end
    end
  end

  def valid_reconciliation_results
    result = normalized_hash(reconciliation_results)
    integers = RECONCILIATION_FIELDS.excluding("all_card_attempts_resolved", "all_devices_synced")
      .index_with { |field| integer_value(result[field], :reconciliation_results, field) }
    return if errors[:reconciliation_results].any?

    if integers.any? { |_field, value| value.negative? }
      errors.add(:reconciliation_results, "counts, latency, and variance values cannot be negative")
    end
    errors.add(:reconciliation_results, "generated ticket count must be at least 500") if integers["generated_ticket_count"] < 500
    manifest_ticket_count = strict_integer(normalized_hash(manifest_results)["ticket_count"])
    if manifest_ticket_count && integers["generated_ticket_count"] != manifest_ticket_count
      errors.add(:reconciliation_results, "generated ticket count must match the signed manifest")
    end
    if integers["unique_admissions_expected"] != integers["unique_admissions_observed"]
      errors.add(:reconciliation_results, "unique admission totals must reconcile")
    end
    if integers["duplicate_conflicts_expected"] != integers["duplicate_conflicts_observed"]
      errors.add(:reconciliation_results, "duplicate conflict totals must reconcile")
    end
    unless integers["unique_admissions_expected"].positive? && integers["duplicate_conflicts_expected"].positive?
      errors.add(:reconciliation_results, "admission and duplicate-conflict scenarios must have positive expected counts")
    end
    %w[
      pending_queue_count unresolved_conflict_count unexplained_admission_variance unexplained_inventory_variance
      unexplained_cash_variance_cents unexplained_card_variance_cents
    ].each do |field|
      errors.add(:reconciliation_results, "#{field} must be zero") unless integers[field].zero?
    end
    unless integers["online_scan_p95_ms"].positive? && integers["online_scan_p95_ms"] <= 500
      errors.add(:reconciliation_results, "online scan p95 must be positive and at most 500 ms")
    end
    unless integers["offline_feedback_p95_ms"].positive? && integers["offline_feedback_p95_ms"] <= 100
      errors.add(:reconciliation_results, "offline feedback p95 must be positive and at most 100 ms")
    end
    %w[all_card_attempts_resolved all_devices_synced].each do |field|
      unless ActiveModel::Type::Boolean.new.cast(result[field])
        errors.add(:reconciliation_results, "must confirm #{field}")
      end
    end
  end

  def complete_assignments
    normalized = normalized_hash(assignments)
    ASSIGNMENT_KEYS.each do |key|
      result = normalized_hash(normalized[key])
      ASSIGNMENT_FIELDS.each do |field|
        errors.add(:assignments, "must include #{key}.#{field}") if result[field].to_s.strip.blank?
      end
    end
  end

  def complete_controls
    validate_boolean_matrix(:controls, controls, CONTROL_KEYS)
  end

  def validate_boolean_matrix(attribute, matrix, keys)
    normalized = normalized_hash(matrix)
    missing = keys.reject { |key| normalized[key] == true }
    errors.add(attribute, "must affirm: #{missing.join(', ')}") if missing.any?
  end

  def integer_value(value, attribute, field)
    Integer(value, exception: true)
  rescue ArgumentError, TypeError
    errors.add(attribute, "#{field} must be an integer")
    nil
  end

  def strict_integer(value)
    Integer(value, exception: true)
  rescue ArgumentError, TypeError
    nil
  end

  def time_value(value, attribute, field)
    Time.iso8601(value.to_s)
  rescue ArgumentError
    errors.add(attribute, "#{field} must be an ISO-8601 timestamp")
    nil
  end

  def sha256?(value)
    value.to_s.match?(/\A[0-9a-f]{64}\z/)
  end

  def normalized_hash(value)
    value.respond_to?(:to_h) ? value.to_h.stringify_keys : {}
  end

  def valid_validation_relationship
    return if pilot_validation_review.nil?

    unless pilot_validation_review.event_id == event_id && pilot_validation_review.decision_approval?
      errors.add(:pilot_validation_review, "must be an approval for the same event")
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

    errors.add(:actor_user, "must be independent from the rehearsal submitter")
  end

  def parent_snapshot_matches
    return unless parent_review

    fields = %w[
      pilot_validation_review_id evidence_reference evidence_digest event_state_digest application_revision
      manifest_results device_results scan_results incident_drills door_sales_results reconciliation_results
      assignments controls effective_at expires_at
    ]
    unless fields.all? { |field| public_send(field) == parent_review.public_send(field) }
      errors.add(:base, "Rehearsal snapshot must match the parent review")
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

  def prevent_mutation
    errors.add(:base, "Event-day rehearsal evidence is append-only")
    throw(:abort)
  end
end
