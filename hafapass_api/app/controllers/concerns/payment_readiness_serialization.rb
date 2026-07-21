# frozen_string_literal: true

module PaymentReadinessSerialization
  extend ActiveSupport::Concern

  private

  def payment_readiness_review_json(review)
    return unless review

    review.attributes.slice(
      "id", "actor_user_id", "decision", "evidence_reference", "evidence_digest",
      "provider_state_digest", "provider_approval_reference", "merchant_of_record",
      "fee_tax_schedule_reference", "liability_schedule_reference", "controls",
      "effective_at", "expires_at", "created_at"
    )
  end
end
