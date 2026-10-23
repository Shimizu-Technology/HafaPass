# frozen_string_literal: true

class Api::V1::Admin::RefundReconciliationsController < Api::V1::Admin::BaseController
  include RefundReconciliationControllerActions

  def index
    render json: RefundReconciliationQueue.call(**filters)
  end

  def action
    perform_reconciliation_action
  end

  private

  def reconciliation_organization
    nil
  end

  def filters
    params.permit(:status, :age_days, :event_id, :page, :per_page).to_h.symbolize_keys
  end
end
