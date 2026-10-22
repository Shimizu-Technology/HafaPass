# frozen_string_literal: true

require "timeout"

class MessageDeliveryJob < ApplicationJob
  queue_as :emails

  class UnknownProviderResult < StandardError; end
  class ReplayExpired < StandardError; end

  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  SEND_LEASE = 5.minutes
  PROVIDER_TIMEOUT = 30.seconds

  def perform(delivery_id)
    unless PROVIDER_TIMEOUT.positive? && PROVIDER_TIMEOUT < SEND_LEASE
      raise ArgumentError, "Email provider deadline must be shorter than the send lease"
    end
    delivery = MessageDelivery.find(delivery_id)
    lease_token = SecureRandom.uuid
    previously_unknown = nil
    outcome = delivery.with_lock do
      if terminal?(delivery)
        mark_reminder_sent!(delivery) if delivery.sent? || delivery.delivered?
        next :done
      end
      if delivery.template == "fee_change_notice" &&
          !FeeChangeNotice.find(delivery.metadata.fetch("fee_change_notice_id")).effective_owner?
        delivery.update!(status: :cancelled, last_error: "Recipient is no longer an effective owner")
        AuditLogger.record!(action: "site_settings.fee_change_notice_skipped", auditable: delivery,
          metadata: { fee_change_notice_id: delivery.metadata.fetch("fee_change_notice_id"), reason: "owner_removed" })
        next :done
      end
      if delivery.send_lease_expires_at.present? && delivery.send_lease_expires_at > Time.current
        self.class.set(wait_until: delivery.send_lease_expires_at).perform_later(delivery.id)
        next :busy
      end
      if obsolete_reminder?(delivery)
        delivery.update!(status: :cancelled, last_error: "Reminder was cancelled or rescheduled")
        next :done
      end
      if obsolete_invitation?(delivery)
        delivery.update!(status: :cancelled, last_error: "Invitation was accepted, revoked, expired or resent")
        next :done
      end
      if obsolete_event_change?(delivery)
        delivery.update!(status: :cancelled, last_error: "This is not a material event change")
        next :done
      end
      if delivery.template != "privacy_request_confirmation" && PrivacyEmailSuppression.for?(delivery.recipient)
        delivery.update!(status: :suppressed, suppressed_at: Time.current, last_error: "Privacy deletion suppression")
        next :done
      end
      if delivery.undeliverable_recipient?
        delivery.update!(status: :cancelled, last_error: "Recipient address is a reserved placeholder")
        next :done
      end
      if delivery.promotional? && delivery.event.nil? && delivery.attempts.positive?
        if delivery.provider == "resend" && delivery.outbound_wire_body.blank?
          raise MessageWirePayload::Unavailable, "The frozen legacy payload is unavailable; reconcile before rendering"
        end
        raise MessageWirePayload::Unavailable, "Legacy promotional delivery lacks organizer consent context; reconcile before replay"
      end
      if delivery.marketing_unsubscribed?
        delivery.update!(status: :suppressed, suppressed_at: Time.current, last_error: "Recipient unsubscribed from this organizer")
        next :done
      end
      if delivery.promotional? && delivery.event &&
          !MarketingConsent.opted_in?(organization: delivery.event.organization, email: delivery.recipient)
        delivery.update!(status: :suppressed, suppressed_at: Time.current, last_error: "Recipient has not opted in")
        next :done
      end
      if delivery.suppressed_recipient?
        delivery.update!(status: :suppressed, suppressed_at: Time.current,
          last_error: "Recipient has a prior bounce, complaint, or suppression")
        next :done
      end
      if delivery.promotional? && SiteSetting.instance.business_mailing_address.blank?
        delivery.update!(status: :suppressed, suppressed_at: Time.current,
          last_error: "Promotional send blocked by missing mailing address")
        next :done
      end
      raise ReplayExpired, "Provider result requires reconciliation before replay" if delivery.provider_replay_expired?

      previously_unknown = delivery.provider_outcome_unknown? ||
        (delivery.provider == "resend" && delivery.provider_attempted_at.nil? && delivery.attempts.positive?)
      available = EmailService.configured?
      frozen_request = delivery.outbound_payload.present? || delivery.provider_attempted_at.present? || previously_unknown ||
        (%w[resend simulated].include?(delivery.provider) && delivery.attempts.positive?)
      real_provider = frozen_request ? delivery.provider == "resend" : available
      if (real_provider && !available) || (!real_provider && Rails.env.production?)
        raise EmailService::ProviderDisabled, "The original email transport is unavailable; reconcile before retrying"
      end
      if real_provider && (delivery.transport_context_digest.present? || delivery.provider_attempted_at.present? || previously_unknown)
        EmailService.verify_transport_context!(delivery)
      end
      if real_provider && delivery.outbound_payload.blank? &&
          (delivery.provider_attempted_at.present? || (delivery.provider == "resend" && delivery.attempts.positive?))
        raise MessageWirePayload::Unavailable, "The frozen legacy payload is unavailable; reconcile before rendering"
      end
      if delivery.promotional? && delivery.event.nil?
        if delivery.attempts.positive?
          raise MessageWirePayload::Unavailable, "Legacy promotional delivery lacks organizer consent context; reconcile before replay"
        end
        delivery.update!(status: :suppressed, suppressed_at: Time.current,
          last_error: "Promotional delivery is missing its organizer event")
        next :done
      end
      payload = delivery.outbound_payload.presence || EmailService.prepare_delivery_payload(delivery)
      wire = real_provider ? MessageWirePayload.prepare(delivery, payload) : {}
      delivery.update!(outbound_payload: payload, payload_digest: Digest::SHA256.hexdigest(JSON.generate(payload.sort.to_h)),
        **wire,
        transport_context_digest: real_provider ? (delivery.transport_context_digest || EmailService.transport_context_digest) : nil,
        provider: real_provider ? "resend" : "simulated", attempts: delivery.attempts + 1, status: :queued, last_error: nil,
        provider_attempted_at: real_provider ? (delivery.provider_attempted_at || Time.current) : nil,
        provider_outcome_unknown: real_provider, send_lease_token: lease_token,
        send_lease_expires_at: SEND_LEASE.from_now)
      :send
    end
    unless outcome == :send
      MessageProviderEventProcessor.reconcile_for!(delivery) if outcome == :done
      return
    end

    if delivery.template != "privacy_request_confirmation" && PrivacyEmailSuppression.for?(delivery.recipient)
      delivery.with_lock do
        delivery.update!(status: :suppressed, suppressed_at: Time.current,
          send_lease_token: nil, send_lease_expires_at: nil, last_error: "Privacy deletion suppression")
      end
      return
    end
    if delivery.promotional? && delivery.event && (delivery.marketing_unsubscribed? ||
        !MarketingConsent.opted_in?(organization: delivery.event.organization, email: delivery.recipient) ||
        delivery.suppressed_recipient? ||
        SiteSetting.instance.business_mailing_address.blank?)
      delivery.with_lock do
        delivery.update!(status: :suppressed, suppressed_at: Time.current,
          provider_outcome_unknown: previously_unknown, send_lease_token: nil, send_lease_expires_at: nil,
          last_error: "Promotional send blocked by unsubscribe, provider suppression, or missing mailing address")
      end
      return
    end

    if delivery.template == "fee_change_notice" &&
        !FeeChangeNotice.find(delivery.metadata.fetch("fee_change_notice_id")).effective_owner?
      delivery.with_lock do
        delivery.update!(status: :cancelled, last_error: "Recipient is no longer an effective owner",
          send_lease_token: nil, send_lease_expires_at: nil, provider_outcome_unknown: false)
        AuditLogger.record!(action: "site_settings.fee_change_notice_skipped", auditable: delivery,
          metadata: { fee_change_notice_id: delivery.metadata.fetch("fee_change_notice_id"), reason: "owner_removed" })
      end
      return
    end

    # Lease, payload and unknown marker are durable before any network activity.
    # This works with transaction-pooled PostgreSQL, without session affinity.
    response = Timeout.timeout(PROVIDER_TIMEOUT) { EmailService.send_delivery_payload(delivery) }
    simulated = response.is_a?(Hash) && (response[:simulated] || response["simulated"])
    id = response[:id] || response["id"] if response.respond_to?(:[])
    if delivery.provider == "resend" && (simulated || !id.is_a?(String) || id.blank?)
      raise UnknownProviderResult, "Email provider acceptance did not include a message ID"
    end
    delivery.with_lock do
      unless delivery.send_lease_token == lease_token
        raise UnknownProviderResult, "Provider request lease changed; reconcile acceptance before replay"
      end
      delivery.update!(status: :sent, provider_id: id, sent_at: Time.current,
        failed_at: nil, last_error: nil, provider_outcome_unknown: false,
        send_lease_token: nil, send_lease_expires_at: nil)
      mark_reminder_sent!(delivery)
    end
    MessageProviderEventProcessor.reconcile_for!(delivery)
  rescue StandardError => error
    delivery&.with_lock do
      if !terminal?(delivery) && (delivery.send_lease_token.nil? || delivery.send_lease_token == lease_token)
        # A definite rejection can clear uncertainty only if no older attempt
        # was already unknown. Never reinterpret an earlier lost response.
        unknown = delivery.provider_outcome_unknown?
        unknown = false if !previously_unknown && known_rejection?(error)
        delivery.update!(status: :failed, failed_at: Time.current,
          provider_outcome_unknown: unknown, last_error: "#{error.class}: #{error.message}".first(1000),
          send_lease_token: nil, send_lease_expires_at: nil)
      end
    end
    Sentry.capture_exception(error, extra: { message_delivery_id: delivery_id })
    raise
  end

  private

  def known_rejection?(error)
    error.is_a?(Resend::Error::InvalidRequestError) || error.is_a?(Resend::Error::NotFoundError) ||
      error.is_a?(Resend::Error::RateLimitExceededError) ||
      error.is_a?(EmailService::ProviderDisabled)
  end

  def terminal?(delivery)
    delivery.provider_id.present? || delivery.sent? || delivery.delivered? || delivery.bounced? ||
      delivery.complained? || delivery.suppressed? || delivery.cancelled?
  end

  def obsolete_reminder?(delivery)
    return false unless delivery.template == "event_reminder"

    reminder = EventReminder.find_by(id: delivery.metadata["event_reminder_id"])
    scheduled_for = delivery.metadata["scheduled_for"]
    reminder.nil? || !reminder.pending? || scheduled_for.blank? || reminder.remind_at.iso8601(6) != scheduled_for
  end

  # An unsent invitation email whose link is no longer the current one must
  # never go out: a newer email (or no email) replaces it.
  def obsolete_invitation?(delivery)
    return false if delivery.outbound_payload.present?

    invitation, open = case delivery.template
    when "organization_invitation"
      membership = delivery.organization_membership
      [membership, membership&.status_invited? && membership.invitation_open?]
    when "platform_invitation"
      record = delivery.platform_invitation
      [record, record&.display_status == "pending"]
    else
      return false
    end
    !open || invitation.invitation_version != delivery.metadata["invitation_version"].to_i
  end

  def obsolete_event_change?(delivery)
    return false unless delivery.template == "event_change"

    change = EventChange.find_by(id: delivery.metadata["event_change_id"])
    !change || !EventChange::TYPES.include?(change.change_type) || change.event_id != delivery.order&.event_id
  end

  def mark_reminder_sent!(delivery)
    return unless delivery.template == "event_reminder"

    reminder = EventReminder.find_by(id: delivery.metadata["event_reminder_id"])
    return unless reminder&.pending?
    return unless reminder.remind_at.iso8601(6) == delivery.metadata["scheduled_for"]

    reminder.update!(status: :sent, sent_at: delivery.sent_at || Time.current)
  end
end
