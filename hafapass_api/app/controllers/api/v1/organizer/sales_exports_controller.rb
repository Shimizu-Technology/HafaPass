# frozen_string_literal: true

class Api::V1::Organizer::SalesExportsController < Api::V1::Organizer::BaseController
  include SpreadsheetExport

  before_action :set_event

  LARGE_EXPORT_THRESHOLD = 10_000

  def create
    return unless can_view_sales?

    query = OrganizerSalesQuery.new(event: @event, params: params)
    columns = params[:columns].is_a?(Array) ? params[:columns] : params[:columns].to_s.split(",").reject(&:blank?)
    builder = OrganizerSalesExport.new(query: query, columns: columns.presence || default_columns,
      finance: finance?, attendees: attendees?)
    count = query.count
    if count > LARGE_EXPORT_THRESHOLD && !S3Service.configured?
      return render json: { error: "Large export storage is unavailable" }, status: :service_unavailable
    end

    metadata = { filters: query.filters, columns: builder.columns, row_count: count, view: query.view }
    export_request = nil
    blocked = false
    # Lock the actor row while counting and inserting the audit record. This
    # serializes requests across app processes, including different events.
    current_user.with_lock do
      if AuditLog.where(actor_user: current_user, action: "sales.export_requested", occurred_at: 1.hour.ago..).count >= 10
        blocked = true
      else
        export_request = OrganizerSalesExportRequest.create!(event: @event, actor_user: current_user,
          filters: query.filters, columns: builder.columns, row_count: count) if count > LARGE_EXPORT_THRESHOLD
        AuditLogger.record!(action: "sales.export_requested", auditable: @event, actor: current_user,
          organization: current_organization, metadata: metadata.merge(export_request_id: export_request&.id), request: request)
      end
    end
    return render json: { error: "Export limit reached. Try again later." }, status: :too_many_requests if blocked

    response.headers["Cache-Control"] = "no-store"
    if export_request
      OrganizerSalesExportJob.perform_later(export_request.id)
      return render json: { id: export_request.id, status: export_request.status,
        download_url: "/api/v1/organizer/events/#{@event.id}/sales_exports/#{export_request.id}" }, status: :accepted
    end

    audit = lambda do |action, outcome|
      AuditLogger.record!(action: action, auditable: @event, actor: current_user,
        organization: current_organization, metadata: metadata.merge(outcome: outcome), request: request)
    end
    stream_csv(filename: "#{@event.slug}-sales.csv", header: builder.header, rows: builder.each_row, bom: true,
      on_complete: -> { audit.call("sales.export_generated", "generated"); audit.call("sales.export_downloaded", "downloaded") },
      on_error: -> { audit.call("sales.export_failed", "stream_failed") })
  rescue OrganizerSalesQuery::InvalidFilter => error
    render json: { error: error.message }, status: :unprocessable_entity
  end

  def index
    return unless can_view_sales?

    OrganizerSalesExportRequest.where(event: @event, actor_user: current_user).fail_expired_processing!
    response.headers["Cache-Control"] = "no-store"
    exports = OrganizerSalesExportRequest.where(event: @event, actor_user: current_user)
      .where(created_at: 1.day.ago..).order(created_at: :desc).limit(10)
    render json: { exports: exports.filter_map { |item|
      next if item.status == "expired" || (item.expires_at && item.expires_at <= Time.current)
      begin
        query = OrganizerSalesQuery.new(event: @event, params: item.filters)
        OrganizerSalesExport.new(query: query, columns: item.columns, finance: finance?, attendees: attendees?)
      rescue OrganizerSalesQuery::InvalidFilter
        next
      end
      { id: item.id, status: item.status, created_at: item.created_at, expires_at: item.expires_at,
        row_count: item.row_count, download_url: "/api/v1/organizer/events/#{@event.id}/sales_exports/#{item.id}" }
    } }
  end

  def show
    return unless can_view_sales?

    OrganizerSalesExportRequest.where(id: params[:id], event: @event, actor_user: current_user).fail_expired_processing!
    export_request = OrganizerSalesExportRequest.find_by!(id: params[:id], event: @event, actor_user: current_user)
    response.headers["Cache-Control"] = "no-store"
    return head :gone if export_request.status == "expired"
    return render json: { status: "failed", error: export_request.failure_reason || "Export failed. Run it again." }, status: :unprocessable_entity if export_request.status == "failed"
    return render json: { status: export_request.status }, status: :accepted unless export_request.status == "ready"
    return head :gone if export_request.expires_at <= Time.current

    query = OrganizerSalesQuery.new(event: @event, params: export_request.filters)
    OrganizerSalesExport.new(query: query, columns: export_request.columns, finance: finance?, attendees: attendees?)
    response.headers["Content-Type"] = "text/csv; charset=utf-8"
    response.headers["Content-Disposition"] = ActionDispatch::Http::ContentDisposition.format(
      disposition: "attachment", filename: "#{@event.slug}-sales.csv")
    response.headers.delete("Content-Length")
    self.response_body = Enumerator.new do |output|
      begin
        client = Aws::S3::Client.new(region: ENV.fetch("AWS_REGION", "us-west-2"),
          credentials: Aws::Credentials.new(ENV["AWS_ACCESS_KEY_ID"], ENV["AWS_SECRET_ACCESS_KEY"], ENV["AWS_SESSION_TOKEN"]))
        client.get_object(bucket: ENV.fetch("AWS_BUCKET"), key: export_request.storage_key) { |chunk| output << chunk }
        audit_download(export_request, "downloaded")
      rescue StandardError => error
        audit_download(export_request, "stream_failed")
        Rails.logger.error("Sales export download failed for request #{export_request.id}: #{error.class}")
        raise
      end
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

    pdf = Admissions::DoorListPdf.new(@event, tickets: query.each_batch).generate
    AuditLogger.record!(action: "sales.door_list_exported", auditable: @event, actor: current_user,
      organization: current_organization, metadata: { filters: query.filters, row_count: query.count }, request: request)
    response.headers["Cache-Control"] = "no-store"
    send_data pdf,
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

  def attendees?
    OrganizationAuthorization.allowed?(user: current_user, organization: current_organization,
      permission: :view_attendees, event: @event)
  end

  def can_view_sales?
    return true if finance? || attendees?

    render json: { error: "You do not have permission to export sales" }, status: :forbidden
    false
  end

  def default_columns
    if attendees?
      OrganizerSalesExport::DEFAULT_COLUMNS - (finance? ? [] : OrganizerSalesExport::FINANCE_COLUMNS)
    else
      OrganizerSalesExport::TRANSACTION_COLUMNS
    end
  end

  def audit_download(export_request, outcome)
    action = outcome == "downloaded" ? "sales.export_downloaded" : "sales.export_download_failed"
    AuditLogger.record!(action: action, auditable: @event, actor: current_user,
      organization: current_organization,
      metadata: { export_request_id: export_request.id, outcome: outcome }, request: request)
  end
end
