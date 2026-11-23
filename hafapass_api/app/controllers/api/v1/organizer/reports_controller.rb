# frozen_string_literal: true

class Api::V1::Organizer::ReportsController < Api::V1::Organizer::BaseController
  include SpreadsheetExport

  REPORT_PERMISSIONS = {
    "sales_by_tier" => :view_finance, "attendance" => :view_attendees,
    "demographics" => :view_attendees, "registrations_roster" => :view_attendees
  }.freeze
  SHOW_PERMISSIONS = REPORT_PERMISSIONS.except("registrations_roster").merge("payouts" => :view_finance).freeze

  before_action :set_event
  before_action :load_permissions

  rescue_from OrganizerSalesQuery::InvalidFilter, with: :invalid_filter

  def show
    type = params[:report_type].presence
    return invalid_report unless type.nil? || SHOW_PERMISSIONS.key?(type)
    return unless authorize_report(type, SHOW_PERMISSIONS)

    report
    result = if type
      report_data(type)
    else
      SHOW_PERMISSIONS.keys.select { |key| @permissions[SHOW_PERMISSIONS[key]] }
        .reduce({}) { |data, key| data.deep_merge(report_data(key)) }
    end
    response.headers["Cache-Control"] = "no-store"
    render json: result
  end

  def export
    type = params[:report_type]
    return invalid_report unless REPORT_PERMISSIONS.key?(type)
    return unless authorize_report(type, REPORT_PERMISSIONS)

    query = roster_query if type == "registrations_roster"
    if query && query.count > OrganizerSalesQuery::MAX_SNAPSHOT_IDS
      raise OrganizerSalesQuery::InvalidFilter, "The roster is too large. Filter it before downloading."
    end

    header, rows = EventReportExport.new(report: report, report_type: type, roster: query).data
    view = type.tr("_", "-")
    AuditLogger.record!(action: "sales.exported", auditable: @event, actor: current_user,
      organization: current_organization, metadata: { view: type }, request: request)
    stream_csv(filename: "#{@event.slug}-#{view}.csv", header: header, rows: rows, bom: true)
  end

  private

  def set_event
    @event = find_organization_event(params[:event_id])
  end

  def load_permissions
    @permissions = OrganizationAuthorization.permissions_for(user: current_user, organization: current_organization, event: @event)
  end

  def authorize_report(type, permissions)
    return true if type ? @permissions[permissions.fetch(type)] : permissions.values.any? { |key| @permissions[key] }

    render json: { error: "You do not have permission to view this report" }, status: :forbidden
    false
  end

  def report_data(type)
    case type
    when "sales_by_tier" then report.sales
    when "attendance"
      attendance = report.attendance
      { attendance: attendance, summary: {
        tickets_active: attendance[:total_active_tickets], tickets_checked_in: attendance[:checked_in_count],
        check_in_rate: attendance[:check_in_rate]
      } }
    when "demographics" then { demographics: report.registrations.demographics }
    when "payouts" then { payout_series: payout_series }
    end
  end

  def payout_series
    return [] unless OrganizationAuthorization.allowed?(user: current_user, organization: current_organization, permission: :view_finance)

    @event.event_series.where(organization_id: current_organization.id).reorder(:name, :id).pluck(:id, :name)
      .map { |id, name| { id: id, name: name } }
  end

  def report
    @report ||= EventReportingService.new(event: @event, params: params)
  end

  def roster_query
    report # The same event-specific filter validation also applies to the roster.
    input = params.permit(:ticket_type_id, :status, :channel, :question_id, :answer_value, :search).to_h
    OrganizerSalesQuery.new(event: @event, params: input, attendee_access: true, active_only: true)
  end

  def invalid_report
    render json: { error: "Invalid report type" }, status: :unprocessable_entity
  end

  def invalid_filter(error)
    render json: { error: error.message }, status: :unprocessable_entity
  end
end
