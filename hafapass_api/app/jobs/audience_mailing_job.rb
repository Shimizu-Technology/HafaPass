# frozen_string_literal: true

class AudienceMailingJob < ApplicationJob
  queue_as :emails
  retry_on StandardError, wait: :polynomially_longer, attempts: 5
  BATCH_SIZE = 100

  def perform(id)
    mailing = AudienceMailing.find(id)
    mailing.with_lock do
      return unless mailing.authorized? && mailing.address.present?
      return unless %w[scheduled queueing].include?(mailing.status)
      return if mailing.scheduled_at && mailing.scheduled_at > Time.current

      if mailing.status == "scheduled"
        mailing.update!(status: "queueing", recipient_emails: mailing.audience_emails)
      end
      emails = mailing.recipient_emails.slice(mailing.cursor, BATCH_SIZE) || []
      emails.each do |email|
        delivery = mailing.delivery(email)
        delivery.save!
        MessageDeliveryJob.perform_later(delivery.id)
      end
      mailing.update!(cursor: mailing.cursor + emails.size, status: emails.size < BATCH_SIZE ? "queued" : "queueing")
      self.class.perform_later(id) if mailing.status == "queueing"
    end
  end
end
