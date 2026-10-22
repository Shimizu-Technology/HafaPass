# frozen_string_literal: true

class SendWaitlistNotificationJob < ApplicationJob
  queue_as :emails

  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(waitlist_entry_id)
    entry = WaitlistEntry.find_by(id: waitlist_entry_id)
    return unless entry&.notified?

    EmailService.send_waitlist_notification_async(entry)
    Rails.logger.info("[SendWaitlistNotificationJob] Queued notification for waitlist entry #{waitlist_entry_id}")
  rescue => e
    entry&.with_lock do
      entry.update!(status: :waiting, expires_at: nil, delivery_failure: "Unable to queue alert: #{e.message}".first(255)) if entry.notified?
    end
    Rails.logger.error("[SendWaitlistNotificationJob] Failed for entry #{waitlist_entry_id}: #{e.message}")
    raise
  end
end
