# frozen_string_literal: true

class SendGuestListNotificationJob < ApplicationJob
  queue_as :emails

  # Retry with exponential backoff for transient failures
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(guest_entry_id)
    guest_entry = GuestListEntry.find_by(id: guest_entry_id)
    return unless guest_entry # Entry was deleted

    EmailService.send_guest_list_notification(guest_entry)
    Rails.logger.info("[SendGuestListNotificationJob] Sent notification for guest entry #{guest_entry_id}")
  rescue => e
    Rails.logger.error("[SendGuestListNotificationJob] Failed for guest entry #{guest_entry_id}: #{e.message}")
    raise # Re-raise to trigger retry
  end
end
