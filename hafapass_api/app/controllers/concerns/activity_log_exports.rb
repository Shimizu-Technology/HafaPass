# frozen_string_literal: true

# Exports retain only filters and a fixed ID ceiling. Every download rechecks
# membership/grants and rebuilds the redacted projection, including retention
# redactions made since the request. No long-lived signed storage URL bypasses it.
module ActivityLogExports
  extend ActiveSupport::Concern
  include SpreadsheetExport

  included do
    before_action :require_activity_export_access
    rescue_from ActivityLogQuery::InvalidFilter do |error|
      render json: { error: error.message }, status: :unprocessable_entity
    end
    rescue_from ActiveRecord::RecordNotFound do
      render json: { error: "Export not found" }, status: :not_found
    end
  end

  def create
    query = export_query(request.query_parameters.merge(request.request_parameters))
    ticket = nil
    current_user.with_lock do
      if AuditLog.where(actor_user: current_user, action: "activity_log.export_requested", occurred_at: 1.hour.ago..).count >= 10
        return render json: { error: "Export limit reached. Try again later." }, status: :too_many_requests
      end
      ticket = ActivityLogExportTicket.issue("actor_user_id" => current_user.id, "organization_id" => export_organization&.id,
        "admin" => export_admin?, "filters" => query.filters, "access_fingerprint" => export_fingerprint,
        "upper_id" => query.base.maximum(:id) || 0, "expires_at" => 1.day.from_now.iso8601)
      audit_export(ActivityLogExportTicket.read(ticket), "requested", outcome: "requested")
    end
    response.headers["Cache-Control"] = "no-store"
    render json: { export: export_json(ActivityLogExportTicket.read(ticket), ticket) }, status: :created
  end

  def show
    item = find_export
    return unless item

    response.headers["Cache-Control"] = "no-store"
    render json: { export: export_json(item, params[:id]) }
  end

  def download
    item = find_export
    return unless item
    return render json: { error: "Export failed. Request it again." }, status: :unprocessable_entity if failed_export?(item)

    query = export_query(item.fetch("filters"))
    scope = query.relation.where("audit_logs.id <= ?", item.fetch("upper_id"))
    member_ids = export_organization&.organization_memberships&.where&.not(user_id: nil)&.pluck(:user_id)&.to_set
    count = 0
    rows = Enumerator.new do |output|
      # Keyset batches avoid both unbounded memory and OFFSET shifts. IDs bound
      # the snapshot; occurrence time is the same primary ordering as the feed.
      remaining = scope
      loop do
        batch = remaining.includes(:actor_user, :organization, :event).order(occurred_at: :desc, id: :desc).limit(500).to_a
        break if batch.empty?

        batch.each do |entry|
          presenter = ActivityLogPresenter.new(entry, organization: export_organization, member_ids: member_ids)
          data = export_admin? ? presenter.admin_json : presenter.organization_json
          output << csv_row(data)
          count += 1
        end
        last = batch.last
        remaining = scope.where("(audit_logs.occurred_at, audit_logs.id) < (?, ?)", last.occurred_at, last.id)
      end
      # Completion auditing stays inside the stream's failure boundary.
      # If it fails, the CSV ends with the explicit incomplete-file marker.
      AuditLog.transaction do
        audit_export(item, "generated", row_count: count)
        audit_export(item, "downloaded", row_count: count)
      end
    end
    failed = lambda do
      audit_export(item, "failed", outcome: "failed", row_count: count)
    end
    header = ["Occurred at (Guam)", "Person", "Person email", "Activity", "Area", "Outcome", "Event", "Event link", "What changed"]
    header += ["Action", "Organization", "Source", "Target type", "Target ID", "Request ID", "Technical details"] if export_admin?
    stream_csv(filename: "hafapass-activity-#{item.fetch("export_request_id")}.csv", header: header, rows: rows, bom: true,
      on_error: failed)
  end

  private

  def export_admin? = false
  def export_organization = export_admin? ? nil : current_organization

  def require_activity_export_access
    return if export_admin?

    @activity_access = OrganizationActivityAccess.new(user: current_user, organization: current_organization)
    return if @activity_access.allowed?

    render json: { error: "You do not have permission to export activity" }, status: :forbidden
  end

  def export_fingerprint = export_admin? ? "admin:#{current_user.id}" : @activity_access.fingerprint

  def export_query(filters)
    ActivityLogQuery.new(scope: export_admin? ? AuditLog.all : @activity_access.relation,
      params: filters, organization: export_organization, admin: export_admin?)
  end

  def find_export
    item = ActivityLogExportTicket.read(params[:id])
    unless item
      head :gone
      return
    end
    unless item["actor_user_id"] == current_user.id && item["organization_id"] == export_organization&.id && item["admin"] == export_admin?
      raise ActiveRecord::RecordNotFound
    end
    if item["access_fingerprint"] != export_fingerprint
      render json: { error: "Your activity access changed. Request a new export." }, status: :forbidden
      return
    end
    item
  end

  def export_json(item, ticket)
    prefix = export_admin? ? "admin" : "organizer"
    { id: ticket, status: failed_export?(item) ? "failed" : "ready", expires_at: item.fetch("expires_at"),
      download_url: "/api/v1/#{prefix}/activity_log_exports/#{ticket}/download" }
  end

  def audit_export(item, stage, outcome: "succeeded", row_count: nil)
    event = export_organization&.events&.find_by(id: item.fetch("filters")["event_id"])
    action = { "requested" => "activity_log.export_requested", "generated" => "activity_log.export_generated",
      "downloaded" => "activity_log.export_downloaded", "failed" => "activity_log.export_failed" }.fetch(stage)
    AuditLogger.record!(action: action, auditable: export_organization || current_user, actor: current_user,
      organization: export_organization, event: event, source: export_admin? ? "admin" : "user", outcome: outcome,
      metadata: { export_request_id: item.fetch("export_request_id"), row_count: row_count }, request: request)
  end

  def failed_export?(item)
    AuditLog.where(actor_user: current_user, action: "activity_log.export_failed")
      .where("metadata ->> 'export_request_id' = ?", item.fetch("export_request_id")).exists?
  end

  def csv_row(data)
    changed = data.fetch(:changes).map { |item| "#{item[:field]}: #{item[:before].inspect} → #{item[:after].inspect}" }.join("; ")
    values = [data[:occurred_at].in_time_zone("Pacific/Guam").iso8601, data.dig(:actor, :name), data.dig(:actor, :email),
      data[:sentence], data[:area], data[:outcome], data.dig(:event, :title), data.dig(:event, :url), changed]
    if export_admin?
      values += [data[:action], data.dig(:organization, :name), data[:source], data.dig(:target, :type),
        data.dig(:target, :id), data[:request_id], { before: data[:before_data], after: data[:after_data], metadata: data[:metadata] }.to_json]
    end
    values
  end
end
