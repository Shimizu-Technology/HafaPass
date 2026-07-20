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
    ).merge(payout_ready: account.payout_ready?)
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
