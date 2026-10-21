# frozen_string_literal: true

require "csv"
require "tempfile"

class OrganizerSalesExportJob < ApplicationJob
  queue_as :default

  def perform(export_id)
    uploaded = false
    claimed_at = Time.current
    return unless OrganizerSalesExportRequest.where(id: export_id)
      .where("status = 'pending' OR (status = 'processing' AND COALESCE(claimed_at, updated_at) <= ?)",
        OrganizerSalesExportRequest::LEASE_DURATION.ago)
      .update_all(status: "processing", claimed_at: claimed_at, failure_reason: nil, updated_at: claimed_at) == 1

    export_request = OrganizerSalesExportRequest.find(export_id)
    query = OrganizerSalesQuery.new(event: export_request.event, params: export_request.filters)
    org = export_request.event.organization
    finance = OrganizationAuthorization.allowed?(user: export_request.actor_user, organization: org,
      permission: :view_finance, event: export_request.event)
    attendees = OrganizationAuthorization.allowed?(user: export_request.actor_user,
      organization: org, permission: :view_attendees, event: export_request.event)
    raise "Export access revoked" unless finance || attendees

    builder = OrganizerSalesExport.new(query: query, columns: export_request.columns,
      finance: finance, attendees: attendees)
    key = "private/sales-exports/#{org.id}/#{export_request.id}-#{SecureRandom.hex(12)}.csv"
    count = 0
    Tempfile.create(["sales-export", ".csv"]) do |file|
      file.binmode
      file.write("\xEF\xBB\xBF".b)
      file.write(CSV.generate_line(builder.header, force_quotes: true))
      builder.each_row do |row|
        file.write(CSV.generate_line(row.map { |value| SpreadsheetExport.safe_value(value) }, force_quotes: true))
        count += 1
      end
      file.flush
      file.rewind
      raise "Export storage unavailable" unless S3Service.configured?

      # Bucket owner enforced disables ACLs. The bucket policy grants public reads
      # only under uploads/*, so this private/sales-exports key stays private.
      Aws::S3::Client.new(region: ENV.fetch("AWS_REGION", "us-west-2"),
        credentials: Aws::Credentials.new(ENV["AWS_ACCESS_KEY_ID"], ENV["AWS_SECRET_ACCESS_KEY"], ENV["AWS_SESSION_TOKEN"]))
        .put_object(bucket: ENV.fetch("AWS_BUCKET"), key: key, body: file,
          content_type: "text/csv; charset=utf-8", cache_control: "no-store")
      uploaded = true
    end
    AuditLogger.record!(action: "sales.export_generated", auditable: export_request.event,
      actor: export_request.actor_user, organization: org,
      metadata: { export_request_id: export_request.id, filters: query.filters,
        columns: builder.columns, row_count: count, outcome: "generated" })
    expires_at = 1.day.from_now
    saved = OrganizerSalesExportRequest.where(id: export_id, status: "processing", claimed_at: claimed_at)
      .update_all(status: "ready", storage_key: key, row_count: count, expires_at: expires_at, updated_at: Time.current)
    raise "Export lease expired or was superseded" unless saved == 1
    OrganizerSalesExportCleanupJob.set(wait_until: expires_at).perform_later(export_request.id)
  rescue StandardError
    if uploaded
      begin
        Aws::S3::Client.new(region: ENV.fetch("AWS_REGION", "us-west-2"),
          credentials: Aws::Credentials.new(ENV["AWS_ACCESS_KEY_ID"], ENV["AWS_SECRET_ACCESS_KEY"], ENV["AWS_SESSION_TOKEN"]))
          .delete_object(bucket: ENV.fetch("AWS_BUCKET"), key: key)
      rescue StandardError => cleanup_error
        Rails.logger.error("Sales export cleanup failed for request #{export_id}: #{cleanup_error.class}")
      end
    end
    OrganizerSalesExportRequest.where(id: export_id, status: %w[processing ready], claimed_at: claimed_at)
      .update_all(status: "failed", storage_key: nil, expires_at: nil,
        failure_reason: "Export generation failed. Run it again.", updated_at: Time.current) if claimed_at
    raise
  end
end
