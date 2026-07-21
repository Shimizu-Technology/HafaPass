# frozen_string_literal: true

class LivePilotIncident < ApplicationRecord
  PAUSE_CATEGORIES = %w[
    uncertain_payment duplicate_charge oversell credential_compromise cross_tenant_disclosure
    widespread_entry_failure
  ].freeze
  CATEGORIES = (PAUSE_CATEGORIES + %w[
    provider_outage checkout_failure delivery_failure scanner_sync_failure support_escalation
    venue_or_schedule_change other
  ]).freeze

  belongs_to :live_pilot_run
  belongs_to :event
  belongs_to :parent_incident, class_name: "LivePilotIncident", optional: true
  belongs_to :actor_user, class_name: "User"
  has_one :resolution, class_name: "LivePilotIncident", foreign_key: :parent_incident_id,
    dependent: :restrict_with_error, inverse_of: :parent_incident

  enum :action, { report: 0, resolution: 1 }, prefix: true
  enum :severity, { p0: 0, p1: 1, p2: 2, p3: 3 }, prefix: true

  validates :category, inclusion: { in: CATEGORIES }
  validates :summary, :evidence_reference, :evidence_digest, :occurred_at, presence: true
  validates :evidence_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validate :relationships_match
  validate :valid_parent_relationship

  attr_readonly :live_pilot_run_id, :event_id, :parent_incident_id, :actor_user_id, :action, :severity,
    :category, :summary, :evidence_reference, :evidence_digest, :occurred_at

  before_update :prevent_mutation
  before_destroy :prevent_mutation

  def pause_required?
    severity_p0? || severity_p1? || PAUSE_CATEGORIES.include?(category)
  end

  private

  def relationships_match
    errors.add(:event, "must match the pilot run") if live_pilot_run && live_pilot_run.event_id != event_id
    if parent_incident && (parent_incident.live_pilot_run_id != live_pilot_run_id || parent_incident.event_id != event_id)
      errors.add(:parent_incident, "must belong to the same pilot run")
    end
  end

  def valid_parent_relationship
    if action_report?
      errors.add(:parent_incident, "must be absent for a report") if parent_incident
    elsif parent_incident.nil? || !parent_incident.action_report?
      errors.add(:parent_incident, "must be an incident report")
    end
  end

  def prevent_mutation
    errors.add(:base, "Live-pilot incidents are append-only")
    throw(:abort)
  end
end
