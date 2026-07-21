# frozen_string_literal: true

class Api::V1::Admin::ConnectedAccountsController < Api::V1::Admin::BaseController
  def update
    account = ConnectedAccount.find(params[:id])
    account = ConnectedAccounts::Manager.sync!(
      account: account,
      attributes: account_params,
      actor: current_user,
      request: request
    )
    render json: account.attributes.slice(
      "id", "organization_id", "provider", "provider_account_id", "status", "charges_enabled",
      "payouts_enabled", "details_submitted", "requirements_due", "capabilities", "last_synced_at"
    ).merge(
      payout_ready: account.payout_ready?,
      readiness_submission: readiness_review_json(account.pending_payment_readiness_submission),
      readiness_approval: readiness_review_json(account.latest_payment_readiness_approval),
      readiness_approval_active: account.active_payment_readiness_approval.present?
    )
  rescue ConnectedAccounts::Manager::AccountError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def account_params
    params.permit(
      :provider_account_id, :charges_enabled, :payouts_enabled, :details_submitted, :disabled,
      requirements_due: [], capabilities: {}
    )
  end

  def readiness_review_json(review)
    return nil unless review

    review.attributes.slice(
      "id", "actor_user_id", "decision", "evidence_reference", "evidence_digest",
      "provider_state_digest",
      "provider_approval_reference", "merchant_of_record", "fee_tax_schedule_reference",
      "liability_schedule_reference", "controls", "effective_at", "expires_at", "created_at"
    )
  end
end
