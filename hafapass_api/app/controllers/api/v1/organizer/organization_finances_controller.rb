# frozen_string_literal: true

# Organization-wide finances: read-only totals, per-event settlement and payout
# status, payout history, and CSV exports. Requires view_finance on the
# membership itself; an event-level assignment never unlocks organization money.
class Api::V1::Organizer::OrganizationFinancesController < Api::V1::Organizer::BaseController
  include SpreadsheetExport

  before_action -> { authorize_organization!(:view_finance) }

  def show
    render json: OrganizationFinanceSummary.call(current_organization)
  end

  def orders_export
    events = current_organization.events.order(starts_at: :asc, id: :asc)
    record_export!("orders")
    stream_csv(
      filename: "#{export_name}-orders-#{Date.current.iso8601}.csv",
      header: FinanceExports::ORDER_HEADER,
      rows: FinanceExports.each_order_row(events).lazy.map { |row| FinanceExports.order_csv_values(row) }
    )
  end

  def payouts_export
    record_export!("payouts")
    stream_csv(
      filename: "#{export_name}-payouts-#{Date.current.iso8601}.csv",
      header: FinanceExports::PAYOUT_HEADER,
      rows: FinanceExports.each_payout_row(current_organization.payouts)
    )
  end

  private

  def export_name
    current_organization.slug.presence || "organization-#{current_organization.id}"
  end

  # Exports carry buyer contact details, so each one leaves an audit record.
  def record_export!(kind)
    AuditLogger.record!(action: "finance.exported", auditable: current_organization, actor: current_user,
      organization: current_organization, metadata: { export: kind, scope: "organization" }, request: request)
  end
end
