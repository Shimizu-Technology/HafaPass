# frozen_string_literal: true

class Api::V1::Organizer::AnnualStatementsController < Api::V1::Organizer::BaseController
  before_action -> { authorize_organization!(:view_finance) }

  def show
    year = Integer(params[:year], 10)
    report = AnnualPayeeReport.new(organization: current_organization, year: year)
    response.headers["Cache-Control"] = "no-store"
    AuditLogger.record!(action: "annual_tax_report.statement_downloaded", auditable: current_organization,
      actor: current_user, metadata: { year: year }, request: request)
    send_data report.statement_pdf, filename: "hafapass-annual-statement-#{year}.pdf",
      type: "application/pdf", disposition: "attachment"
  rescue ArgumentError
    render json: { error: "Choose a year from 2000 to 2100" }, status: :unprocessable_entity
  end
end
