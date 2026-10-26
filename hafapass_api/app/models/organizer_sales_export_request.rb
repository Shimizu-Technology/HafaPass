# frozen_string_literal: true

class OrganizerSalesExportRequest < ApplicationRecord
  LEASE_DURATION = 30.minutes
  LEASE_FAILURE_REASON = "Export processing timed out. Run it again.".freeze
  PRIVATE_STORAGE_PREFIX = "private/sales-exports/v2".freeze

  belongs_to :event
  belongs_to :actor_user, class_name: "User"

  validates :status, inclusion: { in: %w[pending processing ready failed expired] }

  def privacy_safe_artifact?
    !columns.include?("notes_custom_answers") ||
      storage_key.to_s.start_with?("#{PRIVATE_STORAGE_PREFIX}/#{event.organization_id}/#{id}-")
  end

  def self.expired_processing
    where(status: "processing").where("COALESCE(claimed_at, updated_at) <= ?", LEASE_DURATION.ago)
  end

  def self.fail_expired_processing!
    expired_processing.update_all(status: "failed", failure_reason: LEASE_FAILURE_REASON, updated_at: Time.current)
  end
end
