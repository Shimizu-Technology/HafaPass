# frozen_string_literal: true

# Keeps waitlist state in step with a delivery that cannot reach the buyer.
class WaitlistDelivery
  ADDRESS_ERROR = "Add and certify your business mailing address in the Marketing postal address section of Settings before sending waitlist alerts or offers"
  UNCONFIRMED = "Delivery unconfirmed; check with the buyer before manually retrying"

  def self.address_ready?(event)
    event.organization.reload.marketing_postal_address_ready?
  end

  def self.ensure_address!(event)
    raise AddressMissing, ADDRESS_ERROR unless address_ready?(event)
  end

  class AddressMissing < StandardError; end

  def self.reconcile_failure!(delivery)
    return unless %w[waitlist_notification waitlist_offer].include?(delivery.template)
    WaitlistLocks.for_delivery(delivery) do
      next if delivery.reconciled_at? || !%w[suppressed failed bounced complained].include?(delivery.status)

      if delivery.complained?
        record_complaint!(delivery)
      elsif delivery.template == "waitlist_offer"
        reconcile_offer!(delivery)
      else
        reconcile_notification!(delivery)
      end
      delivery.update!(reconciled_at: Time.current)
    end
  end

  def self.definitive_failure?(delivery)
    delivery.suppressed? || (delivery.bounced? && !transient_bounce?(delivery)) ||
      (delivery.failed? && !delivery.provider_outcome_unknown?)
  end

  def self.definitive_offer_failure?(delivery)
    delivery.suppressed? || (delivery.bounced? && !transient_bounce?(delivery)) ||
      (delivery.failed? && !delivery.provider_outcome_unknown? &&
        delivery.last_error.to_s.match?(/recipient|mailbox|email address|does not exist/i) &&
        (delivery.last_error.to_s.start_with?("Resend::Error::InvalidRequestError", "Resend::Error::NotFoundError") ||
          MessageProviderEvent.exists?(message_delivery: delivery, event_type: "email.failed")))
  end

  def self.transient_bounce?(delivery)
    bounces = MessageProviderEvent.where(message_delivery: delivery, event_type: "email.bounced",
      occurred_at: delivery.last_event_at)
    bounces.exists? && !bounces.where("COALESCE(payload #>> '{bounce,type}', '') != 'Transient'").exists?
  end

  def self.failure_reason(delivery)
    return "Email bounced: #{delivery.last_error}" if delivery.bounced? && delivery.last_error.present?
    return "Email bounced" if delivery.bounced?

    delivery.last_error.presence || "Email delivery failed"
  end

  def self.same_notification_round?(entry, delivery)
    if delivery.metadata["notified_at"].present?
      entry.notified_at&.iso8601(6) == delivery.metadata["notified_at"]
    else
      entry.notified_at.present? && delivery.created_at >= entry.notified_at
    end
  end

  def self.reconcile_offer!(delivery)
    offer = WaitlistOffer.find_by(id: delivery.metadata["waitlist_offer_id"])
    return unless offer

    # Checkout locks the offer before it can change either the offer or entry.
    return unless offer.offered? && offer.order_id.nil?

    entry = offer.waitlist_entry
    return unless offer.offered? && entry.offered?

    if definitive_offer_failure?(delivery)
      reason = failure_reason(delivery)
      offer.update!(status: :cancelled, token_version: offer.token_version + 1, cancel_reason: reason)
      entry.update!(status: :waiting, expires_at: nil, delivery_failure: reason)
    else
      entry.update!(delivery_failure: UNCONFIRMED)
    end
  end

  def self.reconcile_notification!(delivery)
    entry = WaitlistEntry.find_by(id: delivery.metadata["waitlist_entry_id"])
    return unless entry

    return unless entry.notified? && same_notification_round?(entry, delivery)

    if definitive_failure?(delivery)
      entry.update!(status: :waiting, expires_at: nil, delivery_failure: failure_reason(delivery))
    else
      entry.update!(delivery_failure: UNCONFIRMED)
    end
  end

  def self.record_complaint!(delivery)
    organization = delivery.event&.organization
    return unless organization

    unsubscribe = MarketingUnsubscribe.find_or_initialize_by(organization: organization, email: delivery.recipient)
    unsubscribe.unsubscribed_at ||= Time.current
    unsubscribe.save!
    entry = if delivery.template == "waitlist_offer"
      WaitlistOffer.find_by(id: delivery.metadata["waitlist_offer_id"])&.waitlist_entry
    else
      WaitlistEntry.find_by(id: delivery.metadata["waitlist_entry_id"])
    end
    return unless entry

    entry.update!(delivery_failure: "Recipient complained and opted out") if entry.active?
  end

  def self.reconcile_success!(delivery)
    WaitlistLocks.for_delivery(delivery) { reconcile_success_locked!(delivery) }
  end

  def self.reconcile_success_locked!(delivery)
    return unless delivery.delivered?

    if delivery.template == "waitlist_offer"
      offer = WaitlistOffer.find_by(id: delivery.metadata["waitlist_offer_id"])
      return unless offer

      entry = offer.waitlist_entry
      if offer.cancelled?
        delivery.update!(metadata: delivery.metadata.merge("delivered_after_offer_withdrawal" => true))
        entry.update!(delivery_failure: "A withdrawn offer email was delivered; reissue if inventory is available") if entry.waiting?
      end
      entry.update!(delivery_failure: nil) if offer.offered? && entry.offered? && entry.delivery_failure == UNCONFIRMED
      return
    end
    return unless delivery.template == "waitlist_notification"

    entry = WaitlistEntry.find_by(id: delivery.metadata["waitlist_entry_id"])
    return unless entry

    return unless same_notification_round?(entry, delivery)

    if entry.waiting? && entry.delivery_failure.present?
      entry.update!(status: :notified, expires_at: 24.hours.from_now, delivery_failure: nil)
    elsif entry.notified? && entry.delivery_failure == UNCONFIRMED
      entry.update!(delivery_failure: nil)
    end
  end

  def self.retry_unconfirmed_offer!(entry)
    offer = WaitlistOffer.where(waitlist_entry_id: entry.id, status: :offered).order(id: :desc).first
    return false unless offer

    WaitlistLocks.with(entry: entry, offer: offer) do
      next false unless offer.active? && entry.offered? && entry.delivery_failure == UNCONFIRMED
      if MessageDelivery.where(template: "waitlist_offer", status: :delivered)
          .where("idempotency_key LIKE ?", "waitlist-offer/#{offer.id}%").exists?
        entry.update!(delivery_failure: nil)
        next false
      end

      entry.update!(delivery_failure: nil)
      EmailService.send_waitlist_offer_async(offer,
        idempotency_key: "waitlist-offer/#{offer.id}/retry/#{SecureRandom.uuid}")
      true
    end
  end
end
