# frozen_string_literal: true

module LiveMoneyProofSerialization
  extend ActiveSupport::Concern

  private

  def live_money_authorization_json(authorization)
    return nil unless authorization

    authorization.attributes.slice(
      "id", "event_id", "connected_account_id", "event_day_rehearsal_review_id", "requested_by_user_id",
      "approved_by_user_id", "order_id", "max_amount_cents", "event_state_digest", "application_revision",
      "provider_state_digest", "platform_configuration_digest", "expires_at", "approved_at", "consumed_at",
      "revoked_at", "revocation_reason", "created_at"
    ).merge(available: authorization.approved? && !authorization.consumed? && !authorization.revoked? &&
      authorization.expires_at > Time.current && authorization.current_bindings?)
  end

  def live_money_review_json(review, active:)
    return nil unless review

    review.attributes.slice(
      "id", "organization_id", "connected_account_id", "proof_event_id", "event_day_rehearsal_review_id",
      "authorization_id", "order_id", "payment_id", "partial_refund_id", "final_refund_id",
      "initial_settlement_id", "payout_id", "post_payout_settlement_id", "parent_review_id", "actor_user_id",
      "decision", "evidence_reference", "evidence_digest", "application_revision", "provider_state_digest",
      "platform_configuration_digest", "entity_results", "provider_results", "reconciliation_results",
      "communication_results", "controls", "effective_at", "expires_at", "reason", "created_at"
    ).merge(active: active)
  end

  def live_money_status_json(organization)
    status = LiveMoneyProof.status(organization)
    active_id = status[:active_approval_id]
    status.except(:pending_submission, :latest_approval, :active_approval_id).merge(
      pending_submission: live_money_review_json(status[:pending_submission], active: false),
      latest_approval: live_money_review_json(
        status[:latest_approval], active: status[:latest_approval]&.id == active_id
      )
    )
  end
end
