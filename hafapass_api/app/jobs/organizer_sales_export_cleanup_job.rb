# frozen_string_literal: true

class OrganizerSalesExportCleanupJob < ApplicationJob
  queue_as :default

  def perform(export_id)
    export_request = OrganizerSalesExportRequest.find_by(id: export_id)
    return unless export_request

    export_request.with_lock do
      next unless export_request.status == "ready" && export_request.expires_at <= Time.current
      if RetentionGuard.protected?(export_request)
        Rails.logger.info("Sales export cleanup skipped under legal hold: request_id=#{export_request.id}")
        next
      end

      LegalHold.with_retention_lock(organization_id: export_request.event.organization_id) do
        next if RetentionGuard.protected?(export_request)

        S3Service.delete_private_export!(export_request.storage_key) if export_request.storage_key.present?
        export_request.update!(status: "expired", storage_key: nil)
      end
    end
  end
end
