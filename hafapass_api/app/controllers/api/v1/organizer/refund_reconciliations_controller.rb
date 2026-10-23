# frozen_string_literal: true

class Api::V1::Organizer::RefundReconciliationsController < Api::V1::Organizer::BaseController
  include RefundReconciliationControllerActions

  before_action :authorize_view!, only: :index

  def index
    render json: RefundReconciliationQueue.call(**filters.merge(organization_id: current_organization.id))
  end

  def action
    perform_reconciliation_action
  end

  private

  def authorize_view!
    authorize_organization!(:view_finance)
  end

  def reconciliation_organization
    current_organization
  end

  def filters
    params.permit(:status, :age_days, :event_id, :page, :per_page).to_h.symbolize_keys
  end
end
