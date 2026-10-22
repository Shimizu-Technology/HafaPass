# frozen_string_literal: true

class OrganizerSalesExportCleanupJob < ApplicationJob
  queue_as :default

  def perform(export_id)
    export_request = OrganizerSalesExportRequest.find_by(id: export_id)
    return unless export_request&.status == "ready" && export_request.expires_at <= Time.current
    return if DataRetention.held?(export_request)

    if export_request.storage_key.present?
      raise "Export storage unavailable for cleanup" unless S3Service.configured?

      Aws::S3::Client.new(region: ENV.fetch("AWS_REGION", "us-west-2"),
        credentials: Aws::Credentials.new(ENV["AWS_ACCESS_KEY_ID"], ENV["AWS_SECRET_ACCESS_KEY"], ENV["AWS_SESSION_TOKEN"]))
        .delete_object(bucket: ENV.fetch("AWS_BUCKET"), key: export_request.storage_key)
    end
    export_request.update!(status: "expired", storage_key: nil)
  end
end
