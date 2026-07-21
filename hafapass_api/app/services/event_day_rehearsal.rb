# frozen_string_literal: true

class EventDayRehearsal
  def self.active_approval(event, at: Time.current, validation_approval: nil, state_digest: nil)
    validation_approval ||= PilotValidation.active_approval(event, at: at, state_digest: state_digest)
    return unless validation_approval

    revoked_ids = event.event_day_rehearsal_reviews.revocations.select(:parent_review_id)
    event.event_day_rehearsal_reviews.approvals
      .where.not(id: revoked_ids)
      .where(pilot_validation_review_id: validation_approval.id)
      .where(event_state_digest: validation_approval.event_state_digest)
      .where(application_revision: PilotReadiness.application_revision)
      .where("effective_at <= ? AND expires_at > ?", at, at)
      .order(created_at: :desc).first
  end

  def self.pending_submission(event)
    decided_ids = event.event_day_rehearsal_reviews.where(decision: [:approval, :rejection]).select(:parent_review_id)
    event.event_day_rehearsal_reviews.decision_submission.where.not(id: decided_ids)
      .where("expires_at > ?", Time.current).order(created_at: :desc).first
  end

  def self.latest_approval(event)
    event.event_day_rehearsal_reviews.approvals.order(created_at: :desc).first
  end

  def self.status(event)
    state_digest = PilotReadiness.event_state_digest(event)
    readiness = PilotReadiness.active_approval(event, state_digest: state_digest)
    validation = PilotValidation.active_approval(event, readiness_approval: readiness, state_digest: state_digest)
    approval = active_approval(event, validation_approval: validation, state_digest: state_digest)
    latest = latest_approval(event)
    {
      required: Rails.env.production?, prerequisite_ready: validation.present?, approved: approval.present?,
      candidate_current: latest.present? && latest.application_revision == PilotReadiness.application_revision &&
        latest.event_state_digest == state_digest && latest.pilot_validation_review_id == validation&.id,
      pending_submission: pending_submission(event), latest_approval: latest, active_approval_id: approval&.id,
      required_scan_scenarios: EventDayRehearsalReview::SCAN_KEYS,
      required_incident_drills: EventDayRehearsalReview::INCIDENT_KEYS,
      required_assignments: EventDayRehearsalReview::ASSIGNMENT_KEYS,
      required_controls: EventDayRehearsalReview::CONTROL_KEYS,
      minimum_physical_devices: EventDayRehearsalReview::MINIMUM_PHYSICAL_DEVICES,
      event_state_digest: state_digest, application_revision: PilotReadiness.application_revision
    }
  end

  def self.list_summary(event)
    reviews = event.event_day_rehearsal_reviews.to_a
    decided_ids = reviews.filter_map do |review|
      review.parent_review_id if review.decision_approval? || review.decision_rejection?
    end
    pending = reviews.select do |review|
      review.decision_submission? && review.expires_at > Time.current && !decided_ids.include?(review.id)
    end.max_by(&:created_at)
    latest = reviews.select(&:decision_approval?).max_by(&:created_at)
    { approval_recorded: latest.present?, pending_submission: pending && { id: pending.id, created_at: pending.created_at } }
  end
end
