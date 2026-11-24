# frozen_string_literal: true

class AudienceMailingJob < ApplicationJob
  queue_as :marketing
  retry_on StandardError, wait: :polynomially_longer, attempts: 5
  BATCH_SIZE = 100

  def perform(id)
    mailing = AudienceMailing.find(id)
    mailing.with_lock do
      return unless %w[scheduled queueing].include?(mailing.status)
      if (reason = mailing.block_reason)
        mailing.update!(status: "blocked", blocked_reason: reason)
        return
      end
      return if mailing.scheduled_at > Time.current

      if mailing.status == "scheduled"
        # Delivery rows are the sole recipient snapshot and use existing retention.
        emails = mailing.audience_emails
        emails.each_slice(BATCH_SIZE) do |batch|
          rows = batch.map { |email| mailing.delivery(email).attributes.except("id", "created_at", "updated_at") }
          MessageDelivery.insert_all!(rows) if rows.any?
          mailing.message_deliveries.reset
        end
        mailing.update!(status: "queueing", recipient_count: emails.size, recipient_emails: [])
      end
      deliveries = mailing.message_deliveries.where(template: "audience_mailing").order(:id).offset(mailing.cursor).limit(BATCH_SIZE).to_a
      deliveries.each { |delivery| MessageDeliveryJob.perform_later(delivery.id) }
      mailing.update!(cursor: mailing.cursor + deliveries.size, status: deliveries.size < BATCH_SIZE ? "queued" : "queueing")
      self.class.perform_later(id) if mailing.status == "queueing"
    end
  end
end
