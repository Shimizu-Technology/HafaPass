# frozen_string_literal: true

module PilotValidationSerialization
  extend ActiveSupport::Concern

  private

  def pilot_validation_review_json(review, active:)
    return nil unless review

    review.attributes.slice(
      "id", "event_id", "pilot_readiness_review_id", "parent_review_id", "actor_user_id", "decision",
      "evidence_reference", "evidence_digest", "event_state_digest", "application_revision", "device_matrix",
      "buyer_flows", "organizer_flows", "accessibility_results", "load_results", "controls", "effective_at",
      "expires_at", "reason", "created_at"
    ).merge(active: active)
  end

  def pilot_validation_json(event)
    status = PilotValidation.status(event)
    active_approval_id = status[:active_approval_id]
    status.except(:pending_submission, :latest_approval, :active_approval_id).merge(
      pending_submission: pilot_validation_review_json(status[:pending_submission], active: false),
      latest_approval: pilot_validation_review_json(
        status[:latest_approval], active: status[:latest_approval]&.id == active_approval_id
      )
    )
  end
end
