# frozen_string_literal: true

require "digest"

module CommunicationCampaigns
  class Sender
    class CampaignError < StandardError; end

    def self.call(campaign)
      new(campaign).call
    end

    def initialize(campaign)
      @campaign = campaign
    end

    def call
      deliveries = []
      CommunicationCampaign.transaction do
        campaign.lock!
        unless campaign.draft? || campaign.scheduled?
          raise CampaignError, "Only draft or scheduled campaigns can be sent"
        end
        if SiteSetting.instance.business_mailing_address.blank?
          raise CampaignError, "Set the Business mailing address in admin settings before sending promotional email"
        end
        if PublicSiteUrl.api.blank? && !Rails.env.local?
          raise CampaignError, "PUBLIC_API_URL is required for one-click unsubscribe"
        end

        campaign.update!(status: :sending, started_at: Time.current)
        eligible_recipients.each do |recipient|
          normalized = recipient.fetch(:email).strip.downcase
          deliveries << campaign.message_deliveries.create!(
            event: campaign.event,
            order: recipient[:order],
            requested_by: campaign.created_by_user,
            channel: "email",
            template: "communication_campaign",
            recipient: normalized,
            provider: EmailService.configured? ? "resend" : "simulated",
            idempotency_key: "campaign/#{campaign.id}/#{Digest::SHA256.hexdigest(normalized)}",
            payload_digest: Digest::SHA256.hexdigest([campaign.subject, campaign.body, normalized].join("|")),
            metadata: { subject: campaign.subject, body: campaign.body,
              mailing_address: SiteSetting.instance.business_mailing_address,
              organizer_name: campaign.event.organization.name },
            status: :queued
          )
        end
        campaign.update!(status: :sent, sent_at: Time.current, recipient_count: deliveries.length)
      end
      deliveries.each { |delivery| MessageDeliveryJob.perform_later(delivery.id) }
      campaign
    rescue ActiveRecord::RecordNotUnique
      raise CampaignError, "This campaign has already been queued"
    end

    private

    attr_reader :campaign

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

    def eligible_recipients
      recipients.select do |recipient|
        email = recipient.fetch(:email)
        consented = opted_in?(email)
        unsubscribed = MarketingUnsubscribe.exists?(organization: campaign.event.organization, email: email)
        suppression = MessageDelivery.new(recipient: email).suppressed_recipient?
        consented && !unsubscribed && !suppression
      end
    end

    public

    def audience_counts
      all = recipients
      { attendees: all.length,
        opted_in: all.count { |recipient| opted_in?(recipient[:email]) },
        excluded: all.length - eligible_recipients.length,
        eligible: eligible_recipients.length }
    end

    private

    def opted_in?(email)
      campaign.event.organization.events.joins(:orders)
        .where(orders: { marketing_opt_in: true, status: [Order.statuses[:completed], Order.statuses[:partially_refunded]] })
        .where("LOWER(orders.buyer_email) = ?", email).exists?
    end
  end
end
