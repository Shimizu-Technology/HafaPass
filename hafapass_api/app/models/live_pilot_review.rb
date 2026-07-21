# frozen_string_literal: true

class LivePilotReview < ApplicationRecord
  MAXIMUM_INVENTORY_CAP = 250
  SUPPORT_WINDOWS = %w[before_event during_event after_event].freeze
  SUPPORT_FIELDS = %w[starts_at ends_at primary_reference backup_reference channel_reference acknowledgement_reference].freeze
  ASSIGNMENT_KEYS = %w[
    incident_commander business_owner technical_lead finance_monitor support_lead admissions_lead
    organizer_contact venue_contact
  ].freeze
  ASSIGNMENT_FIELDS = %w[name private_contact_reference acknowledgement_reference].freeze
  THRESHOLD_FIELDS = %w[
    minimum_checkout_conversion_bps maximum_payment_failure_rate_bps maximum_hold_expiry_rate_bps
    maximum_delivery_failure_rate_bps maximum_scanner_conflicts maximum_scanner_sync_lag_seconds
    maximum_checkout_p95_ms maximum_support_contacts_per_100_orders
  ].freeze
  CONTROL_KEYS = %w[
    bounded_inventory_confirmed no_high_demand_public_blast monitoring_dashboard_verified
    provider_status_monitoring_confirmed pause_authority_confirmed support_coverage_confirmed
    guam_change_communications_ready uncertain_payment_response_ready duplicate_charge_response_ready
    oversell_response_ready credential_compromise_response_ready cross_tenant_response_ready
    widespread_entry_failure_response_ready no_open_p0_or_p1 explicit_go_decision
  ].freeze

  belongs_to :event
  belongs_to :event_day_rehearsal_review
  belongs_to :live_money_proof_review, optional: true
  belongs_to :parent_review, class_name: "LivePilotReview", optional: true
  belongs_to :actor_user, class_name: "User"
  has_many :child_reviews, class_name: "LivePilotReview", foreign_key: :parent_review_id,
    dependent: :restrict_with_error, inverse_of: :parent_review
  has_one :live_pilot_run, dependent: :restrict_with_error

  enum :decision, { submission: 0, approval: 1, revocation: 2, rejection: 3 }, prefix: true

  validates :evidence_reference, :evidence_digest, :event_state_digest, :application_revision,
    :effective_at, :expires_at, presence: true
  validates :evidence_digest, :event_state_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :inventory_cap, numericality: {
    only_integer: true, greater_than: 0, less_than_or_equal_to: MAXIMUM_INVENTORY_CAP
  }
  validate :complete_support_coverage
  validate :complete_assignments
  validate :valid_thresholds
  validate :complete_controls
  validate :valid_prerequisites
  validate :valid_parent_relationship
  validate :independent_approver
  validate :parent_snapshot_matches
  validate :reason_present_for_negative_decision
  validate :valid_effective_window
  validate :inventory_cap_fits_event

  attr_readonly :event_id, :event_day_rehearsal_review_id, :live_money_proof_review_id, :parent_review_id,
    :actor_user_id, :decision, :evidence_reference, :evidence_digest, :event_state_digest,
    :application_revision, :inventory_cap, :support_coverage, :assignments, :thresholds, :controls,
    :effective_at, :expires_at, :reason

  before_update :prevent_mutation
  before_destroy :prevent_mutation

  scope :approvals, -> { where(decision: :approval) }
  scope :revocations, -> { where(decision: :revocation) }

  def revoked?
    child_reviews.decision_revocation.exists?
  end

  private

  def complete_support_coverage
    coverage = normalized_hash(support_coverage)
    SUPPORT_WINDOWS.each do |window|
      item = normalized_hash(coverage[window])
      SUPPORT_FIELDS.each do |field|
        errors.add(:support_coverage, "must include #{window}.#{field}") if item[field].to_s.strip.blank?
      end
      starts_at = time_value(item["starts_at"], :support_coverage, "#{window}.starts_at")
      ends_at = time_value(item["ends_at"], :support_coverage, "#{window}.ends_at")
      if starts_at && ends_at && ends_at <= starts_at
        errors.add(:support_coverage, "#{window} must end after it starts")
      end
    end
    validate_support_window_coverage(coverage)
  end

  def validate_support_window_coverage(coverage)
    return unless event&.starts_at && event&.ends_at

    before = parsed_window(coverage["before_event"])
    during = parsed_window(coverage["during_event"])
    after = parsed_window(coverage["after_event"])
    if before && before.last < event.starts_at
      errors.add(:support_coverage, "before-event coverage must continue until the event starts")
    end
    if during && (during.first > event.starts_at || during.last < event.ends_at)
      errors.add(:support_coverage, "during-event coverage must span the entire event")
    end
    if after && (after.first > event.ends_at || after.last < event.ends_at + 2.hours)
      errors.add(:support_coverage, "after-event coverage must start by event end and continue for at least two hours")
    end
  end

  def parsed_window(value)
    item = normalized_hash(value)
    [Time.iso8601(item["starts_at"].to_s), Time.iso8601(item["ends_at"].to_s)]
  rescue ArgumentError
    nil
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

  def valid_thresholds
    values = THRESHOLD_FIELDS.index_with do |field|
      integer_value(normalized_hash(thresholds)[field], :thresholds, field)
    end
    return if errors[:thresholds].any?

    rate_fields = THRESHOLD_FIELDS.grep(/bps\z/)
    if rate_fields.any? { |field| !values[field].between?(0, 10_000) }
      errors.add(:thresholds, "basis-point rates must be between 0 and 10000")
    end
    nonnegative_fields = %w[maximum_scanner_conflicts maximum_support_contacts_per_100_orders]
    if nonnegative_fields.any? { |field| values[field].negative? }
      errors.add(:thresholds, "count thresholds must be non-negative")
    end
    positive_fields = THRESHOLD_FIELDS - rate_fields - nonnegative_fields
    if positive_fields.any? { |field| !values[field].positive? }
      errors.add(:thresholds, "latency thresholds must be positive")
    end
  end

  def complete_controls
    normalized = normalized_hash(controls)
    missing = CONTROL_KEYS.reject { |key| normalized[key] == true }
    errors.add(:controls, "must affirm: #{missing.join(', ')}") if missing.any?
  end

  def valid_prerequisites
    if event_day_rehearsal_review &&
        (!event_day_rehearsal_review.decision_approval? || event_day_rehearsal_review.event_id != event_id)
      errors.add(:event_day_rehearsal_review, "must be a Gate G approval for the same event")
    end
    if live_money_proof_review &&
        (!live_money_proof_review.decision_approval? || live_money_proof_review.organization_id != event&.organization_id)
      errors.add(:live_money_proof_review, "must be a Gate H approval for the event organization")
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

    errors.add(:actor_user, "must be independent from the pilot-plan submitter")
  end

  def parent_snapshot_matches
    return unless parent_review

    fields = %w[
      event_day_rehearsal_review_id live_money_proof_review_id evidence_reference evidence_digest
      event_state_digest application_revision inventory_cap support_coverage assignments thresholds controls
      effective_at expires_at
    ]
    errors.add(:base, "Live-pilot snapshot must match the parent review") unless
      fields.all? { |field| public_send(field) == parent_review.public_send(field) }
  end

  def reason_present_for_negative_decision
    return unless (decision_revocation? || decision_rejection?) && reason.to_s.strip.blank?

    errors.add(:reason, "is required for a revocation or rejection")
  end

  def valid_effective_window
    return if effective_at.blank? || expires_at.blank?

    errors.add(:expires_at, "must be after the effective time") unless expires_at > effective_at
  end

  def inventory_cap_fits_event
    return unless event && inventory_cap.is_a?(Integer)

    configured = event.ticket_types.sum(:quantity_available)
    maximum = [event.max_capacity || configured, configured].min
    errors.add(:inventory_cap, "cannot exceed configured event inventory or capacity") if inventory_cap > maximum
  end

  def integer_value(value, attribute, field)
    Integer(value, exception: true)
  rescue ArgumentError, TypeError
    errors.add(attribute, "#{field} must be an integer")
    nil
  end

  def time_value(value, attribute, field)
    Time.iso8601(value.to_s)
  rescue ArgumentError
    errors.add(attribute, "#{field} must be an ISO-8601 timestamp")
    nil
  end

  def normalized_hash(value)
    value.respond_to?(:to_h) ? value.to_h.stringify_keys : {}
  end

  def prevent_mutation
    errors.add(:base, "Live-pilot evidence is append-only")
    throw(:abort)
  end
end
