# frozen_string_literal: true

class SendWaitlistNotificationJob < ApplicationJob
  queue_as :emails

  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(waitlist_entry_id)
    entry = WaitlistEntry.find_by(id: waitlist_entry_id)
    return unless entry

    EmailService.send_waitlist_notification(entry)
    Rails.logger.info("[SendWaitlistNotificationJob] Sent notification for waitlist entry #{waitlist_entry_id}")
  rescue => e
    Rails.logger.error("[SendWaitlistNotificationJob] Failed for entry #{waitlist_entry_id}: #{e.message}")
    raise
  end
end
