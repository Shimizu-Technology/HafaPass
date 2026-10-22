# frozen_string_literal: true

class OrganizerSalesExportCleanupJob < ApplicationJob
  queue_as :default

  def perform(export_id)
    export_request = OrganizerSalesExportRequest.find_by(id: export_id)
    return unless export_request&.status == "ready" && export_request.expires_at <= Time.current
    if DataRetention.held?(export_request)
      Rails.logger.info("Sales export cleanup skipped under legal hold: request_id=#{export_request.id}")
      return
    end

    if export_request.storage_key.present?
      S3Service.delete_private_export!(export_request.storage_key)
    end
    export_request.update!(status: "expired", storage_key: nil)
  end
end
