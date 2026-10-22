# frozen_string_literal: true

class Api::V1::Admin::TaxInformationsController < Api::V1::Admin::BaseController
  def reveal
    record = Organization.find(params[:organization_id]).organizer_tax_information
    return render json: { error: "No W-9 on file" }, status: :not_found unless record

    AuditLogger.record!(action: "organizer_tax_information.revealed", auditable: record, actor: current_user,
      organization: record.organization, request: request)
    response.headers["Cache-Control"] = "no-store, no-cache"
    render json: { tin: record.tin }
  end
end
