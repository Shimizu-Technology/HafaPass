# frozen_string_literal: true

class Api::V1::Admin::LiveMoneyProofAuthorizationsController < Api::V1::Admin::BaseController
  include LiveMoneyProofSerialization

  def create
    authorization = LiveMoneyProofAuthorizations::Manager.request!(
      event: Event.find(params[:event_id]), buyer_email: params[:buyer_email],
      max_amount_cents: params[:max_amount_cents], expires_at: params[:expires_at],
      actor: current_user, request: request
    )
    render json: live_money_authorization_json(authorization), status: :created
  rescue LiveMoneyProofAuthorizations::Manager::AuthorizationError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def approve
    authorization = LiveMoneyProofAuthorizations::Manager.approve!(
      authorization: LiveMoneyProofAuthorization.find(params[:id]), actor: current_user, request: request
    )
    render json: live_money_authorization_json(authorization), status: :ok
  rescue LiveMoneyProofAuthorizations::Manager::AuthorizationError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def revoke
    authorization = LiveMoneyProofAuthorizations::Manager.revoke!(
      authorization: LiveMoneyProofAuthorization.find(params[:id]), actor: current_user,
      reason: params[:reason], request: request
    )
    render json: live_money_authorization_json(authorization), status: :ok
  rescue LiveMoneyProofAuthorizations::Manager::AuthorizationError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
end
