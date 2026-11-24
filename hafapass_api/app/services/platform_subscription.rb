# frozen_string_literal: true

class PlatformSubscription
  def self.call(attributes, request: nil, ip: nil, user_agent: nil)
    email = attributes[:email].to_s.strip.downcase
    return unless email.match?(URI::MailTo::EMAIL_REGEXP) && email.length <= 254

    subscriber = PlatformSubscriber.find_or_create_by!(email: email) do |row|
      row.assign_attributes(attributes.except(:email).merge(source: attributes[:source].presence || "footer"))
    end
    subscriber.with_lock do
      return subscriber if subscriber.status == "confirmed" || %w[bounced complained].include?(subscriber.status)
      return subscriber if subscriber.message_deliveries.where(template: "platform_confirmation").where("created_at > ?", 30.days.ago).count >= Integer(ENV.fetch("PLATFORM_CONFIRMATIONS_PER_30_DAYS", "3"))
      return subscriber if subscriber.status == "pending" && subscriber.message_deliveries.where("created_at > ?", 1.hour.ago).exists?

      subscriber.update!(source: attributes[:source].presence || subscriber.source, status: "pending", confirmation_nonce: SecureRandom.hex(24))
      EmailConsent.record!(email: email, scope: "platform", action: "requested", source: subscriber.source, request: request, ip: ip, user_agent: user_agent)
      if PlatformSubscriber.confirmation_required?
        delivery = subscriber.message_deliveries.create!(channel: "email", template: "platform_confirmation", recipient: email,
          provider: EmailService.configured? ? "resend" : "simulated", status: :queued,
          idempotency_key: "platform-confirm/#{subscriber.id}/#{subscriber.confirmation_nonce}",
          metadata: { token: subscriber.confirmation_token })
        ActiveRecord.after_all_transactions_commit { MessageDeliveryJob.perform_later(delivery.id) }
      else
        subscriber.update!(status: "confirmed", confirmed_at: Time.current)
        EmailConsent.record!(email: email, scope: "platform", action: "confirmed", source: subscriber.source, request: request, ip: ip, user_agent: user_agent)
      end
    end
    subscriber
  end
end
