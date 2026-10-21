# frozen_string_literal: true

class Api::V1::Organizer::SalesExportsController < Api::V1::Organizer::BaseController
  include SpreadsheetExport

  before_action :set_event

  LARGE_EXPORT_THRESHOLD = 10_000

  def create
    return unless can_view_sales?
    return render json: { error: "Export limit reached. Try again later." }, status: :too_many_requests if rate_limited?

    query = OrganizerSalesQuery.new(event: @event, params: params)
    columns = params[:columns].is_a?(Array) ? params[:columns] : params[:columns].to_s.split(",").reject(&:blank?)
    builder = OrganizerSalesExport.new(query: query, columns: columns.presence || default_columns,
      finance: finance?, contacts: contacts?)
    count = query.count
    if count > LARGE_EXPORT_THRESHOLD && !S3Service.configured?
      return render json: { error: "Large export storage is unavailable" }, status: :service_unavailable
    end

    metadata = { filters: query.filters, columns: builder.columns, row_count: count, view: query.view }
    AuditLogger.record!(action: "sales.exported", auditable: @event, actor: current_user,
      organization: current_organization, metadata: metadata, request: request)
    response.headers["Cache-Control"] = "no-store"
    if count > LARGE_EXPORT_THRESHOLD
      export_request = OrganizerSalesExportRequest.create!(event: @event, actor_user: current_user,
        filters: query.filters, columns: builder.columns, row_count: count)
      OrganizerSalesExportJob.perform_later(export_request.id)
      return render json: { id: export_request.id, status: export_request.status,
        download_url: "/api/v1/organizer/events/#{@event.id}/sales_exports/#{export_request.id}" }, status: :accepted
    end

    stream_csv(filename: "#{@event.slug}-sales.csv", header: builder.header, rows: builder.each_row, bom: true)
  rescue OrganizerSalesQuery::InvalidFilter => error
    render json: { error: error.message }, status: :unprocessable_entity
  end

  def show
    return unless can_view_sales?

    export_request = OrganizerSalesExportRequest.find_by!(id: params[:id], event: @event, actor_user: current_user)
    response.headers["Cache-Control"] = "no-store"
    return head :gone if export_request.status == "expired"
    return render json: { status: "failed", error: "Export failed. Please try again." }, status: :unprocessable_entity if export_request.status == "failed"
    return render json: { status: export_request.status }, status: :accepted unless export_request.status == "ready"
    return head :gone if export_request.expires_at <= Time.current

    # Recheck permission at download time; a revoked member cannot follow an
    # old link to customer data.
    query = OrganizerSalesQuery.new(event: @event, params: export_request.filters)
    OrganizerSalesExport.new(query: query, columns: export_request.columns, finance: finance?, contacts: contacts?)
    response.headers["Content-Type"] = "text/csv; charset=utf-8"
    response.headers["Content-Disposition"] = ActionDispatch::Http::ContentDisposition.format(
      disposition: "attachment", filename: "#{@event.slug}-sales.csv")
    response.headers.delete("Content-Length")
    self.response_body = Enumerator.new do |output|
      client = Aws::S3::Client.new(region: ENV.fetch("AWS_REGION", "us-west-2"),
        credentials: Aws::Credentials.new(ENV["AWS_ACCESS_KEY_ID"], ENV["AWS_SECRET_ACCESS_KEY"], ENV["AWS_SESSION_TOKEN"]))
      client.get_object(bucket: ENV.fetch("AWS_BUCKET"), key: export_request.storage_key) { |chunk| output << chunk }
    end
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Export not found" }, status: :not_found
  rescue OrganizerSalesQuery::InvalidFilter
    render json: { error: "Export access changed" }, status: :forbidden
  end

  def door_list
    return unless can_view_sales?
    unless OrganizationAuthorization.allowed?(user: current_user, organization: current_organization,
      permission: :view_attendees, event: @event)
      return render json: { error: "Door list requires attendee access" }, status: :forbidden
    end

    query = OrganizerSalesQuery.new(event: @event, params: params.to_unsafe_h.merge("view" => "tickets"))
    return render json: { error: "Door list is limited to 5,000 tickets" }, status: :unprocessable_entity if query.count > 5_000

    AuditLogger.record!(action: "sales.door_list_exported", auditable: @event, actor: current_user,
      organization: current_organization, metadata: { filters: query.filters, row_count: query.count }, request: request)
    response.headers["Cache-Control"] = "no-store"
    send_data Admissions::DoorListPdf.new(@event, tickets: query.each_batch).generate,
      filename: "#{@event.slug}-door-list.pdf", type: "application/pdf", disposition: "attachment"
  rescue OrganizerSalesQuery::InvalidFilter => error
    render json: { error: error.message }, status: :unprocessable_entity
  end

  private

  def set_event
    @event = find_organization_event(params[:event_id])
  end

  def finance?
    OrganizationAuthorization.allowed?(user: current_user, organization: current_organization,
      permission: :view_finance, event: @event)
  end

  def contacts?
    finance? || OrganizationAuthorization.allowed?(user: current_user, organization: current_organization,
      permission: :view_attendees, event: @event)
  end

  def can_view_sales?
    return true if contacts?

    render json: { error: "You do not have permission to export sales" }, status: :forbidden
    false
  end

  def default_columns
    OrganizerSalesExport::DEFAULT_COLUMNS - (finance? ? [] : OrganizerSalesExport::FINANCE_COLUMNS)
  end

  def rate_limited?
    AuditLog.where(actor_user: current_user, action: "sales.exported", occurred_at: 1.hour.ago..).count >= 10
  end
end
