# frozen_string_literal: true

module EventDayRehearsalSerialization
  extend ActiveSupport::Concern

  private

  def event_day_rehearsal_review_json(review, active:)
    return nil unless review

    review.attributes.slice(
      "id", "event_id", "pilot_validation_review_id", "parent_review_id", "actor_user_id", "decision",
      "evidence_reference", "evidence_digest", "event_state_digest", "application_revision", "manifest_results",
      "device_results", "scan_results", "incident_drills", "door_sales_results", "reconciliation_results",
      "assignments", "controls", "effective_at", "expires_at", "reason", "created_at"
    ).merge(active: active)
  end

  def event_day_rehearsal_json(event)
    status = EventDayRehearsal.status(event)
    active_id = status[:active_approval_id]
    status.except(:pending_submission, :latest_approval, :active_approval_id).merge(
      pending_submission: event_day_rehearsal_review_json(status[:pending_submission], active: false),
      latest_approval: event_day_rehearsal_review_json(
        status[:latest_approval], active: status[:latest_approval]&.id == active_id
      )
    )
  end
end
