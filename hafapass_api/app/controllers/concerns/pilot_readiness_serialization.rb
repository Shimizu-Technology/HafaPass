# frozen_string_literal: true

module PilotReadinessSerialization
  extend ActiveSupport::Concern

  private

  def pilot_readiness_review_json(review)
    return nil unless review

    review.attributes.slice(
      "id", "event_id", "parent_review_id", "actor_user_id", "decision", "evidence_reference",
      "evidence_digest", "event_state_digest", "application_revision", "controls", "assignments", "effective_at",
      "expires_at", "reason", "created_at"
    ).merge(active: review.active?)
  end

  def pilot_readiness_json(event)
    status = PilotReadiness.status(event)
    status.except(:pending_submission, :latest_approval).merge(
      pending_submission: pilot_readiness_review_json(status[:pending_submission]),
      latest_approval: pilot_readiness_review_json(status[:latest_approval])
    )
  end
end
