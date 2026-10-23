# frozen_string_literal: true

class CommunicationCampaignDispatchJob < ApplicationJob
  queue_as :emails
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(campaign_id)
    campaign = CommunicationCampaign.find(campaign_id)
    return unless campaign.sending? || campaign.failed?
    return if campaign.failed? && campaign.last_error == CommunicationCampaign::AUTHORIZATION_ERROR

    authorized = false
    campaign.event.organization.with_lock do
      campaign.lock!
      return unless campaign.sending? || campaign.failed?
      return if campaign.failed? && campaign.last_error == CommunicationCampaign::AUTHORIZATION_ERROR

      authorized = campaign.sender_authorized?
      campaign.fail_authorization! unless authorized
    end
    return unless authorized

    # No transaction surrounds enqueueing: child jobs cannot merely defer their
    # enqueue until after a completion audit commits. Existing delivery leases
    # and terminal-state guards make crash/partial-enqueue retries idempotent.
    campaign.message_deliveries.order(:id).each do |delivery|
      job = MessageDeliveryJob.perform_later(delivery.id)
      raise ActiveJob::EnqueueError, "Campaign delivery enqueue rejected" unless job && job.successfully_enqueued?
    end
    campaign.with_lock do
      if campaign.sending? || campaign.failed?
        return if campaign.failed? && campaign.last_error == CommunicationCampaign::AUTHORIZATION_ERROR

        campaign.update!(status: :sent, sent_at: Time.current, last_error: nil)
        AuditLogger.record!(action: "campaign.send_completed", auditable: campaign, event: campaign.event,
          outcome: "succeeded", metadata: { delivery_phase: "queueing", recipient_count: campaign.recipient_count })
      end
    end
  rescue StandardError => error
    if campaign
      campaign.with_lock do
        if (campaign.sending? || campaign.failed?) && campaign.last_error != CommunicationCampaign::AUTHORIZATION_ERROR
          campaign.update!(status: :failed, sent_at: nil,
            last_error: "Campaign deliveries could not all be queued. Review and retry the send.")
        end
        AuditLogger.record!(action: "campaign.send_failed", auditable: campaign, event: campaign.event,
          outcome: "failed", metadata: { failure_code: "delivery_enqueue_failed", exception_type: error.class.name })
      end
    end
    raise
  end
end
