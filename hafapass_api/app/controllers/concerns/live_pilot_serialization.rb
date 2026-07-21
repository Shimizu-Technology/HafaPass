# frozen_string_literal: true

module LivePilotSerialization
  extend ActiveSupport::Concern

  private

  def live_pilot_review_json(review, active:)
    return nil unless review

    review.attributes.slice(
      "id", "event_id", "event_day_rehearsal_review_id", "live_money_proof_review_id", "parent_review_id",
      "actor_user_id", "decision", "evidence_reference", "evidence_digest", "event_state_digest",
      "application_revision", "inventory_cap", "support_coverage", "assignments", "thresholds", "controls",
      "effective_at", "expires_at", "reason", "created_at"
    ).merge(active: active)
  end

  def live_pilot_incident_json(incident)
    incident.attributes.slice(
      "id", "live_pilot_run_id", "event_id", "parent_incident_id", "actor_user_id", "action", "severity",
      "category", "summary", "evidence_reference", "evidence_digest", "occurred_at", "created_at"
    ).merge(resolved: incident.action_report? && incident.resolution.present?, pause_required: incident.pause_required?)
  end

  def live_pilot_metric_json(snapshot)
    return nil unless snapshot

    snapshot.attributes.slice(
      "id", "live_pilot_run_id", "event_id", "recorded_by_user_id", "local_metrics", "external_metrics",
      "breached_thresholds", "evidence_reference", "evidence_digest", "observed_at", "created_at"
    ).merge(pause_required: snapshot.pause_required?)
  end

  def live_pilot_run_json(run)
    return nil unless run

    run.attributes.slice(
      "id", "event_id", "live_pilot_review_id", "started_by_user_id", "completed_by_user_id", "status",
      "started_at", "paused_at", "completed_at", "pause_reason", "completion_evidence_reference",
      "completion_evidence_digest", "completion_results", "created_at"
    ).merge(
      inventory_cap: run.inventory_cap,
      committed_ticket_quantity: LivePilot.committed_ticket_quantity(run.event),
      incidents: run.live_pilot_incidents.order(:occurred_at).map { |incident| live_pilot_incident_json(incident) },
      latest_metric_snapshot: live_pilot_metric_json(run.live_pilot_metric_snapshots.order(observed_at: :desc).first)
    )
  end

  def live_pilot_status_json(event)
    status = LivePilot.status(event)
    active_id = status[:active_approval_id]
    status.except(:pending_submission, :latest_approval, :latest_run, :active_approval_id).merge(
      pending_submission: live_pilot_review_json(status[:pending_submission], active: false),
      latest_approval: live_pilot_review_json(
        status[:latest_approval], active: status[:latest_approval]&.id == active_id
      ),
      latest_run: live_pilot_run_json(status[:latest_run])
    )
  end
end
