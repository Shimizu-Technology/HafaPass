# frozen_string_literal: true

class Api::V1::Admin::TaxReportsController < Api::V1::Admin::BaseController
  include SpreadsheetExport
  before_action :prepare_report

  ORGANIZER_HEADER = %w[organization snapshot_status legal_name business_name classification tin_type masked_tin tax_mailing_address exempt_payee_code w9_on_file gross_ticket_proceeds gross_add_on_proceeds gross_donation_proceeds gross_other_proceeds gross_non_ticket_proceeds ticket_refunds non_ticket_refunds unallocated_refunds fee_refunds fees_collected reconciliation_adjustments net_paid currency].freeze
  RECEIPTS_HEADER = %w[month service_fees_collected service_fees_refunded gross_receipts card_processing_costs currency].freeze

  def show
    render json: @report.as_json
  end

  def organizers_export
    export_organizers
  end

  # Deliberate POST: only this audited action includes complete TINs.
  def preparation_export
    full_tin = ActiveModel::Type::Boolean.new.cast(params[:include_full_tins])
    purpose = params[:purpose].to_s.strip
    if full_tin && !BackupWithholding.safe_reason?(purpose)
      return render json: { error: "Full-TIN export requires a 10-1000 character purpose without a TIN" }, status: :unprocessable_entity
    end
    export_organizers(full_tin: full_tin, purpose: purpose)
  end

  def receipts_export
    audit_export!("monthly_gross_receipts")
    rows = @report.months.map do |row|
      [format("%04d-%02d", @report.year, row[:month]),
        *row.values_at(:fees_collected_cents, :fees_refunded_cents, :gross_receipts_cents, :card_processing_costs_cents).map { |value| FinanceExports.money(value) }, "USD"]
    end
    stream_csv(filename: "hafapass-gross-receipts-#{@report.year}.csv", header: RECEIPTS_HEADER, rows: rows)
  end

  private

  def prepare_report
    response.headers["Cache-Control"] = "no-store"
    @report = TaxReports.new(params[:year].presence || Date.current.year)
  rescue ArgumentError
    render json: { error: "Choose a year from 2000 to 2100" }, status: :unprocessable_entity
  end

  def export_organizers(full_tin: false, purpose: nil)
    # Build sensitive rows before streaming so errors cannot log secret content.
    rows = @report.organizers.map do |row|
      tax = row[:tax_information] || {}
      values = [row[:organization_name], row[:tax_snapshot_status], *tax.values_at("legal_name", "business_name", "tax_classification", "tin_type", "masked_tin", "mailing_address", "exempt_payee_code"), row[:w9_on_file],
        *row.values_at(:gross_ticket_proceeds_cents, :gross_add_on_proceeds_cents, :gross_donation_proceeds_cents,
          :gross_other_proceeds_cents, :gross_non_ticket_proceeds_cents, :ticket_refunds_cents,
          :non_ticket_refunds_cents, :unallocated_refunds_cents, :fee_refunds_cents, :fees_collected_cents, :reconciliation_adjustments_cents,
          :net_paid_cents).map { |value| FinanceExports.money(value) }, "USD"]
      if full_tin
        values << (Payout.find(row[:tax_snapshot_payout_id]).tax_information_tin if row[:tax_snapshot_status] == "W-9 snapshotted at payout")
      end
      values
    end
    audit_export!(full_tin ? "1099_preparation_full_tin" : "organizer_payouts", count: rows.length, purpose: full_tin ? purpose : nil)
    header = full_tin ? ORGANIZER_HEADER + ["full_tin_for_1099_preparation_import_as_text"] : ORGANIZER_HEADER
    stream_csv(filename: "organizer-#{full_tin ? 'SENSITIVE-FULL-TINS' : 'payouts-masked'}-#{@report.year}.csv", header: header, rows: rows)
  end

  def audit_export!(kind, count: nil, purpose: nil)
    AuditLogger.record!(action: "tax_report.exported", auditable: current_user, actor: current_user,
      metadata: { export: kind, year: @report.year, organization_ids: @report.organization_ids,
        count: count, purpose: purpose }, request: request)
  end
end
