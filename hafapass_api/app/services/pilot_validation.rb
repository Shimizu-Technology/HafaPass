# frozen_string_literal: true

class PilotValidation
  def self.active_approval(event, at: Time.current, readiness_approval: nil, state_digest: nil)
    readiness_approval ||= PilotReadiness.active_approval(event, at: at, state_digest: state_digest)
    return unless readiness_approval

    revoked_ids = event.pilot_validation_reviews.revocations.select(:parent_review_id)
    event.pilot_validation_reviews.approvals
      .where.not(id: revoked_ids)
      .where(pilot_readiness_review_id: readiness_approval.id)
      .where(event_state_digest: readiness_approval.event_state_digest)
      .where(application_revision: PilotReadiness.application_revision)
      .where("effective_at <= ? AND expires_at > ?", at, at)
      .order(created_at: :desc).first
  end

  def self.pending_submission(event)
    decided_ids = event.pilot_validation_reviews.where(decision: [:approval, :rejection]).select(:parent_review_id)
    event.pilot_validation_reviews.decision_submission.where.not(id: decided_ids)
      .where("expires_at > ?", Time.current).order(created_at: :desc).first
  end

  def self.latest_approval(event)
    event.pilot_validation_reviews.approvals.order(created_at: :desc).first
  end

  def self.status(event)
    state_digest = PilotReadiness.event_state_digest(event)
    readiness = PilotReadiness.active_approval(event, state_digest: state_digest)
    approval = active_approval(event, readiness_approval: readiness, state_digest: state_digest)
    latest = latest_approval(event)
    {
      required: Rails.env.production?,
      prerequisite_ready: readiness.present?,
      approved: approval.present?,
      candidate_current: latest.present? && latest.application_revision == PilotReadiness.application_revision &&
        latest.event_state_digest == state_digest && latest.pilot_readiness_review_id == readiness&.id,
      pending_submission: pending_submission(event),
      latest_approval: latest,
      required_devices: PilotValidationReview::DEVICE_TARGETS.keys,
      required_buyer_flows: PilotValidationReview::BUYER_FLOW_KEYS,
      required_organizer_flows: PilotValidationReview::ORGANIZER_FLOW_KEYS,
      required_accessibility_checks: PilotValidationReview::ACCESSIBILITY_CHECK_KEYS,
      required_controls: PilotValidationReview::CONTROL_KEYS,
      active_approval_id: approval&.id,
      event_state_digest: state_digest,
      application_revision: PilotReadiness.application_revision
    }
  end

  def self.list_summary(event)
    reviews = event.pilot_validation_reviews.to_a
    decided_submission_ids = reviews.filter_map do |review|
      review.parent_review_id if review.decision_approval? || review.decision_rejection?
    end
    pending = reviews.select do |review|
      review.decision_submission? && review.expires_at > Time.current && !decided_submission_ids.include?(review.id)
    end.max_by(&:created_at)
    latest_approval = reviews.select(&:decision_approval?).max_by(&:created_at)
    {
      approval_recorded: latest_approval.present?,
      pending_submission: pending && { id: pending.id, created_at: pending.created_at }
    }
  end
end
