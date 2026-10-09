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
    delivery = MessageDelivery.find(delivery_id)
    lease_token = SecureRandom.uuid
    previously_unknown = nil
    outcome = delivery.with_lock do
      if terminal?(delivery)
        mark_reminder_sent!(delivery) if delivery.sent? || delivery.delivered?
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
      if delivery.suppressed_recipient?
        delivery.update!(status: :suppressed, suppressed_at: Time.current,
          last_error: "Recipient has a prior bounce, complaint, or suppression")
        next :done
      end
      raise ReplayExpired, "Provider result requires reconciliation before replay" if delivery.provider_replay_expired?

      real_provider = EmailService.configured?
      if !real_provider && Rails.env.production?
        raise EmailService::ProviderDisabled, "Production email is disabled until current Resend evidence is independently approved"
      end
      previously_unknown = delivery.provider_outcome_unknown? ||
        (delivery.provider == "resend" && delivery.provider_attempted_at.nil? && delivery.attempts.positive?)
      payload = delivery.outbound_payload.presence || EmailService.prepare_delivery_payload(delivery)
      delivery.update!(outbound_payload: payload, payload_digest: Digest::SHA256.hexdigest(JSON.generate(payload.sort.to_h)),
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
    error.is_a?(Resend::Error::InvalidRequestError) || error.is_a?(Resend::Error::RateLimitExceededError) ||
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

  def mark_reminder_sent!(delivery)
    return unless delivery.template == "event_reminder"

    reminder = EventReminder.find_by(id: delivery.metadata["event_reminder_id"])
    return unless reminder&.pending?
    return unless reminder.remind_at.iso8601(6) == delivery.metadata["scheduled_for"]

    reminder.update!(status: :sent, sent_at: delivery.sent_at || Time.current)
  end
end
