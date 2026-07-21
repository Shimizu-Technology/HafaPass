# frozen_string_literal: true

class Api::V1::Admin::PlatformCapabilitiesController < Api::V1::Admin::BaseController
  def index
    render json: { capabilities: PlatformCapabilities.names.map { |name| capability_json(name) } }
  end

  private

  def capability_json(name)
    status = PlatformCapabilities.status(name)
    status.except(:pending_submission, :latest_approval).merge(
      pending_submission: review_json(status[:pending_submission]),
      latest_approval: review_json(status[:latest_approval])
    )
  end

  def review_json(review)
    return nil unless review

    review.attributes.slice(
      "id", "parent_review_id", "actor_user_id", "capability", "decision", "evidence_reference",
      "evidence_digest", "configuration_digest", "controls", "effective_at", "expires_at", "reason", "created_at"
    ).merge(active: review.active?)
  end
end
