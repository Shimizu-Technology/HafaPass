# frozen_string_literal: true

class CommunicationCampaignDispatchJob < ApplicationJob
  queue_as :emails
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(campaign_id)
    campaign = CommunicationCampaign.find(campaign_id)
    return unless campaign.sending? || campaign.failed?

    # No transaction surrounds enqueueing: child jobs cannot merely defer their
    # enqueue until after a completion audit commits. Existing delivery leases
    # and terminal-state guards make crash/partial-enqueue retries idempotent.
    campaign.message_deliveries.order(:id).each do |delivery|
      job = MessageDeliveryJob.perform_later(delivery.id)
      raise ActiveJob::EnqueueError, "Campaign delivery enqueue rejected" unless job && job.successfully_enqueued?
    end
    campaign.with_lock do
      unless campaign.sent? || campaign.cancelled?
        campaign.update!(status: :sent, sent_at: Time.current)
        AuditLogger.record!(action: "campaign.send_completed", auditable: campaign, event: campaign.event,
          outcome: "succeeded", metadata: { delivery_phase: "queueing", recipient_count: campaign.recipient_count })
      end
    end
  rescue StandardError => error
    if campaign
      campaign.with_lock do
        campaign.update!(status: :failed, sent_at: nil) unless campaign.sent? || campaign.cancelled?
        AuditLogger.record!(action: "campaign.send_failed", auditable: campaign, event: campaign.event,
          outcome: "failed", metadata: { failure_code: "delivery_enqueue_failed", exception_type: error.class.name })
      end
    end
    raise
  end
end
