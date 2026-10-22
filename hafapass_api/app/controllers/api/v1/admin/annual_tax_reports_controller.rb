# frozen_string_literal: true

require "csv"

class Api::V1::Admin::AnnualTaxReportsController < Api::V1::Admin::BaseController
  before_action -> { response.headers["Cache-Control"] = "no-store" }
  rescue_from ArgumentError do
    render json: { error: "Choose a year from 2000 to 2100" }, status: :unprocessable_entity
  end
  rescue_from ActiveRecord::RecordInvalid do |error|
    render json: { errors: error.record.errors.full_messages }, status: :unprocessable_entity
  end

  def index
    render json: { year: year, reports: reports.map(&:row) }
  end

  def update
    organization = Organization.find(params[:organization_id])
    key = params[:payee_key].to_s
    report = AnnualPayeeReport.for_organization(organization: organization, year: year).find { |candidate| candidate.payee_key == key }
    return render json: { error: "Payee not found in this year" }, status: :not_found unless report

    setting = AnnualTaxReportSetting.find_or_initialize_by(organization: organization, year: year, payee_key: key)
    setting.update!(params.permit(:form_type, :jurisdiction))
    AuditLogger.record!(action: "annual_tax_report.setting_updated", auditable: setting, actor: current_user,
      organization: organization, metadata: { year: year, form_type: setting.form_type,
        jurisdiction: setting.jurisdiction }, request: request)
    render json: report.row
  end

  def export
    rows = reports.map do |report_service|
      report = report_service.row
      [year, ENV["TAX_PAYER_TIN"].presence || "SET_TAX_PAYER_TIN", report[:organization_id], report[:legal_name],
        report_service.payee_tin, report[:masked_tin], report[:form_type], report[:jurisdiction], report[:reporting_status],
        report[:threshold_cents], report[:gross_paid_cents], report[:withheld_cents],
        report[:net_disbursed_cents], report[:refund_clawbacks_cents]]
    end
    AuditLogger.record!(action: "annual_tax_report.exported", auditable: current_user, actor: current_user,
      metadata: { year: year, count: rows.length }, request: request)
    data = CSV.generate do |csv|
      csv << %w[year payer_tin organization_id payee_name payee_tin masked_payee_tin form_type jurisdiction
        reporting_status threshold_cents gross_paid_cents withheld_cents net_disbursed_cents refund_clawbacks_cents]
      rows.each { |row| csv << row.map { |value| value.is_a?(String) && value.start_with?("=", "+", "-", "@") ? "\t#{value}" : value } }
    end
    send_data data, filename: "annual-payees-#{year}.csv", type: "text/csv", disposition: "attachment"
  end

  private

  def year
    @year ||= Integer(params[:year].presence || Date.current.year).tap do |value|
      raise ArgumentError unless (2000..2100).cover?(value)
    end
  end

  def organizations
    @organizations ||= Organization.includes(:organizer_tax_information).where(id: Payout.status_paid.where(paid_at: ActiveSupport::TimeZone["Pacific/Guam"].local(year, 1, 1)...ActiveSupport::TimeZone["Pacific/Guam"].local(year + 1, 1, 1)).select(:organization_id)).order(:id)
  end

  def reports
    @reports ||= organizations.flat_map { |org| AnnualPayeeReport.for_organization(organization: org, year: year) }
  end
end
