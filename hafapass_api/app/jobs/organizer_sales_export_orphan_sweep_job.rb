# frozen_string_literal: true

require "set"

# Uploaded objects may outlive a worker that dies before it can record the key
# or run its rescue cleanup. Sweep the private prefix after a two-day grace
# period, including objects from requests still marked processing.
class OrganizerSalesExportOrphanSweepJob < ApplicationJob
  queue_as :default

  PREFIX = "private/sales-exports/"
  GRACE_PERIOD = 2.days

  def perform
    # An orphan key only identifies its organization, so a narrower hold
    # lookup cannot reliably rule out an event, order, user, or email hold.
    if LegalHold.active.exists?
      Rails.logger.info("Sales export orphan sweep skipped under legal hold")
      return
    end
    OrganizerSalesExportRequest.fail_expired_processing!
    return unless S3Service.configured?

    client = Aws::S3::Client.new(region: ENV.fetch("AWS_REGION", "us-west-2"),
      credentials: Aws::Credentials.new(ENV["AWS_ACCESS_KEY_ID"], ENV["AWS_SECRET_ACCESS_KEY"], ENV["AWS_SESSION_TOKEN"]))
    bucket = ENV.fetch("AWS_BUCKET")
    cutoff = GRACE_PERIOD.ago
    token = nil
    loop do
      page = client.list_objects_v2(bucket: bucket, prefix: PREFIX, continuation_token: token)
      candidates = page.contents.select { |object| object.key.start_with?(PREFIX) && object.last_modified < cutoff }
      associated = OrganizerSalesExportRequest.where(storage_key: candidates.map(&:key))
        .select { |item| item.expires_at.nil? || item.expires_at > cutoff || DataRetention.held?(item) }
        .map(&:storage_key).to_set
      candidates.each do |object|
        next if associated.include?(object.key)

        begin
          organization_id = object.key.delete_prefix(PREFIX).split("/", 2).first
          organization_id = nil unless organization_id.match?(/\A[1-9]\d*\z/)

          LegalHold.with_retention_lock(organization_id: organization_id) do
            next if LegalHold.active.exists?

            linked = OrganizerSalesExportRequest.find_by(storage_key: object.key)
            next if linked && (linked.expires_at.nil? || linked.expires_at > cutoff ||
              RetentionGuard.protected?(linked))

            S3Service.delete_private_export!(object.key)
          end
        rescue Aws::S3::Errors::ServiceError => error
          Rails.logger.error("Sales export orphan sweep: DeleteObject permission or service access failed (#{error.class})")
        end
      end
      break unless page.is_truncated

      token = page.next_continuation_token
    end
  rescue Aws::S3::Errors::ServiceError => error
    Rails.logger.error("Sales export orphan sweep: ListBucket permission or service access failed (#{error.class})")
  end
end
