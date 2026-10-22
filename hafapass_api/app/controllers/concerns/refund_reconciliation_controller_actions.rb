# frozen_string_literal: true

module RefundReconciliationControllerActions
  extend ActiveSupport::Concern

  def perform_reconciliation_action
    result = RefundReconciliationActions.call(type: params[:type], id: params[:id], action: params[:operation],
      actor: current_user, params: params.permit(:reference, :returned_at, :note, :reason), request: request)
    render json: { result: { type: params[:type], id: result.id, status: result.respond_to?(:status) ? result.status : nil } }
  rescue RefundReconciliationActions::Forbidden => e
    render json: { error: e.message }, status: :forbidden
  rescue RefundReconciliationActions::ActionError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
end
