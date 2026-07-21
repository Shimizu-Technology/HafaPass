# frozen_string_literal: true

module PilotCloseoutSerialization
  extend ActiveSupport::Concern

  private

  def pilot_closeout_review_json(review, active:)
    return nil unless review

    review.attributes.slice(
      "id", "event_id", "live_pilot_run_id", "parent_review_id", "actor_user_id", "decision",
      "expansion_decision", "evidence_reference", "evidence_digest", "local_state_digest",
      "application_revision", "local_metrics", "outcome_metrics", "reconciliation_results",
      "cleanup_results", "evidence_references", "retrospective_actions", "expansion_scope",
      "signed_at", "reason", "created_at"
    ).merge(active: active, metric_report: PilotCloseout.metric_report(review))
  end

  def pilot_closeout_status_json(event)
    status = PilotCloseout.status(event)
    active_id = status[:active_approval_id]
    run = status[:completed_run]
    status.except(:pending_submission, :latest_approval, :completed_run, :active_approval_id).merge(
      completed_run: run && {
        id: run.id, status: run.status, started_at: run.started_at, completed_at: run.completed_at,
        completion_evidence_reference: run.completion_evidence_reference,
        completion_evidence_digest: run.completion_evidence_digest
      },
      pending_submission: pilot_closeout_review_json(status[:pending_submission], active: false),
      latest_approval: pilot_closeout_review_json(status[:latest_approval], active: status[:latest_approval]&.id == active_id)
    )
  end
end
