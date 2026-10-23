# frozen_string_literal: true

require "digest"

module CommunicationCampaigns
  class Sender
    class CampaignError < StandardError; end

    def self.call(campaign, actor: nil)
      new(campaign, actor: actor).call
    end

    def initialize(campaign, actor: nil)
      @campaign = campaign
      @actor = actor
    end

    def call
      authorization_error = nil
      organization = campaign.event.organization
      organization.with_lock do
        campaign.lock!
        sender = @actor || campaign.scheduled_by_user || campaign.created_by_user
        AuditContext.set(actor: sender) do
          unless campaign.draft? || campaign.scheduled? || campaign.failed?
            raise CampaignError, "Only draft, scheduled or failed campaigns can be sent"
          end
          unless campaign.sender_authorized?(sender)
            campaign.fail_authorization!
            authorization_error = campaign.last_error
            next
          end
          unless organization.marketing_postal_address_ready?
            raise CampaignError, "The organization owner must certify a valid marketing postal address in Organization settings before sending email"
          end
          if PublicSiteUrl.api.blank? && !Rails.env.local?
            raise CampaignError, "PUBLIC_API_URL is required for one-click unsubscribe"
          end

          # A reviewed/rescheduled failed campaign also retains its outbox.
          retrying = campaign.started_at.present?
          recovering = campaign.failed? || (retrying && campaign.scheduled?)
          campaign.update!(status: :sending, started_at: campaign.started_at || Time.current,
            sent_by_user: sender, last_error: nil, sent_at: nil)
          if recovering
            AuditLogger.record!(action: "campaign.recovered", auditable: campaign, event: campaign.event,
              metadata: { delivery_phase: "queueing" })
          end
          (retrying ? [] : eligible_recipients).each do |recipient|
            normalized = recipient.fetch(:email).strip.downcase
            campaign.message_deliveries.create!(
              event: campaign.event,
              order: recipient[:order],
              requested_by: sender,
              channel: "email",
              template: "communication_campaign",
              recipient: normalized,
              provider: EmailService.configured? ? "resend" : "simulated",
              idempotency_key: "campaign/#{campaign.id}/#{Digest::SHA256.hexdigest(normalized)}",
              payload_digest: Digest::SHA256.hexdigest([campaign.subject, campaign.body, normalized].join("|")),
              metadata: { subject: campaign.subject, body: campaign.body,
                mailing_address: organization.marketing_mailing_address,
                organizer_name: organization.name },
              status: :queued
            )
          end
          if retrying
            campaign.message_deliveries.find_each do |delivery|
              authorization_cancelled = delivery.cancelled? && delivery.last_error == CommunicationCampaign::DELIVERY_AUTHORIZATION_ERROR
              next if delivery.provider_id.present? || %w[sent delivered bounced complained suppressed].include?(delivery.status)
              next if delivery.cancelled? && !authorization_cancelled

              attributes = { requested_by: sender }
              if authorization_cancelled
                attributes.merge!(status: :queued, last_error: nil)
              end
              delivery.update!(attributes)
            end
          end
          campaign.update!(recipient_count: campaign.message_deliveries.count)
          # Dispatch starts after the durable recipient outbox commits.
          context = AuditContext.snapshot
          ActiveRecord.after_all_transactions_commit do
            AuditContext.restore(context) { enqueue_dispatch! }
          end
        end
      end
      raise CampaignError, authorization_error if authorization_error

      campaign
    rescue ActiveRecord::RecordNotUnique
      raise CampaignError, "This campaign has already been queued"
    end

    def audience_counts
      all = recipients
      consented = consented_recipients(all)
      eligible = eligible_recipients(consented)
      { attendees: all.length, opted_in: consented.length,
        excluded: all.length - eligible.length, eligible: eligible.length }
    end

    private

    attr_reader :campaign

    def enqueue_dispatch!
      job = CommunicationCampaignDispatchJob.perform_later(campaign.id)
      raise ActiveJob::EnqueueError, "Campaign dispatcher enqueue rejected" unless job && job.successfully_enqueued?
    rescue StandardError => error
      campaign.with_lock do
        campaign.update!(status: :failed, sent_at: nil, last_error: "Campaign dispatcher could not be queued. Review and retry the send.")
        AuditLogger.record!(action: "campaign.send_failed", auditable: campaign, event: campaign.event,
          outcome: "failed", metadata: { failure_code: "dispatcher_enqueue_failed", exception_type: error.class.name })
      end
      raise
    end

    def recipients
      tickets = campaign.event.tickets.where.not(status: :cancelled).where.not(order_id: nil)
      tickets = tickets.where(status: :checked_in) if campaign.segment_type == "checked_in"
      tickets = tickets.where(status: :issued) if campaign.segment_type == "not_checked_in"
      if campaign.segment_type == "ticket_type"
        tickets = tickets.where(ticket_type_id: campaign.segment.fetch("ticket_type_id"))
      end

      tickets.includes(:order).order(:id).each_with_object({}) do |ticket, grouped|
        next unless ticket.order&.buyer_email.present?

        email = ticket.order.buyer_email.strip.downcase
        grouped[email] ||= { email: email, order: ticket.order }
      end.values
    end

    def consented_recipients(all = recipients)
      all.filter_map do |recipient|
        order = MarketingConsent.latest_order(organization: campaign.event.organization, email: recipient[:email])
        recipient.merge(order: order) if order&.marketing_opt_in?
      end
    end

    def eligible_recipients(consented = consented_recipients)
      consented.reject { |recipient| blocked?(recipient[:email]) }
    end

    def blocked?(email)
      MarketingUnsubscribe.exists?(organization: campaign.event.organization, email: email) ||
        MessageDelivery.new(recipient: email, channel: "email", template: "communication_campaign").suppressed_recipient?
    end
  end
end
