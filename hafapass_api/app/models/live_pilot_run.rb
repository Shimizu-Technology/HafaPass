# frozen_string_literal: true

class LivePilotRun < ApplicationRecord
  belongs_to :event
  belongs_to :live_pilot_review
  belongs_to :started_by_user, class_name: "User"
  belongs_to :completed_by_user, class_name: "User", optional: true
  has_many :live_pilot_run_actions, dependent: :restrict_with_error
  has_many :live_pilot_incidents, dependent: :restrict_with_error
  has_many :live_pilot_metric_snapshots, dependent: :restrict_with_error

  enum :status, { active: 0, paused: 1, completed: 2, aborted: 3 }, prefix: true

  validates :started_at, presence: true
  validate :relationships_match
  validate :valid_completion_state
  validate :valid_pause_state
  validate :valid_abort_state

  attr_readonly :event_id, :live_pilot_review_id, :started_by_user_id, :started_at

  def inventory_cap
    live_pilot_review.inventory_cap
  end

  def unresolved_incidents
    resolved_ids = live_pilot_incidents.action_resolution.select(:parent_incident_id)
    live_pilot_incidents.action_report.where.not(id: resolved_ids)
  end

  private

  def relationships_match
    return unless event && live_pilot_review

    errors.add(:live_pilot_review, "must approve the same event") unless
      live_pilot_review.event_id == event_id && live_pilot_review.decision_approval?
  end

  def valid_completion_state
    completed_fields = [completed_at, completed_by_user_id, completion_evidence_reference,
      completion_evidence_digest].map(&:present?)
    if status_completed? && !completed_fields.all?
      errors.add(:base, "Completed pilot runs require actor, time, evidence reference, and digest")
    elsif !status_completed? && completed_fields.any?
      errors.add(:base, "Completion fields are only allowed on completed pilot runs")
    end
  end

  def valid_pause_state
    pause_fields = [paused_at, pause_reason].map(&:present?)
    if status_paused? && !pause_fields.all?
      errors.add(:base, "Paused pilot runs require a time and reason")
    elsif !status_paused? && pause_fields.any?
      errors.add(:base, "Pause fields are only allowed on paused pilot runs")
    end
  end

  def valid_abort_state
    abort_fields = [aborted_at, abort_reason].map(&:present?)
    if status_aborted? && !abort_fields.all?
      errors.add(:base, "Aborted pilot runs require a time and reason")
    elsif !status_aborted? && abort_fields.any?
      errors.add(:base, "Abort fields are only allowed on aborted pilot runs")
    end
  end
end
