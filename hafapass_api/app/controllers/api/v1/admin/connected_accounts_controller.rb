# frozen_string_literal: true

class Api::V1::Admin::ConnectedAccountsController < Api::V1::Admin::BaseController
  before_action -> { response.headers["Cache-Control"] = "no-store" }

  def approve_payout_method
    account = ConnectedAccount.find(params[:id])
    controls = params[:controls].respond_to?(:permit) ? params[:controls].permit(*PaymentReadinessReview::MANUAL_CONTROL_KEYS).to_h : {}
    PayoutMethodReview.approve!(account: account, actor: current_user, controls: controls,
      expected_digest: params[:expected_digest], review_by: params[:review_by], note: params[:note], request: request)
    render json: PayoutMethodReview.account_json(account.reload), status: :created
  rescue PayoutMethodReview::StateChanged => e
    render json: { error: e.message }, status: :conflict
  rescue PayoutMethodReview::ReviewError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def request_payout_changes
    account = ConnectedAccount.find(params[:id])
    PayoutMethodReview.request_changes!(account: account, actor: current_user,
      expected_digest: params[:expected_digest], note: params[:note], request: request)
    render json: PayoutMethodReview.account_json(account.reload), status: :created
  rescue PayoutMethodReview::StateChanged => e
    render json: { error: e.message }, status: :conflict
  rescue PayoutMethodReview::ReviewError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def update
    account = ConnectedAccount.find(params[:id])
    account = ConnectedAccounts::Manager.sync!(
      account: account,
      attributes: account_params,
      actor: current_user,
      request: request
    )
    active_approval = account.active_payment_readiness_approval
    render json: account.attributes.slice(
      "id", "organization_id", "provider", "provider_account_id", "status", "charges_enabled",
      "payouts_enabled", "details_submitted", "requirements_due", "capabilities", "last_synced_at"
    ).merge(
      payout_ready: account.payout_ready?,
      readiness_submission: payment_readiness_review_json(account.pending_payment_readiness_submission),
      readiness_approval: payment_readiness_review_json(account.latest_payment_readiness_approval),
      readiness_approval_active: active_approval.present?
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
end
