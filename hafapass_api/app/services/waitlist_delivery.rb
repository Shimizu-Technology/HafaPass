# frozen_string_literal: true

# Keeps waitlist state in step with a delivery that cannot reach the buyer.
class WaitlistDelivery
  ADDRESS_ERROR = "Add your business mailing address in Settings before sending waitlist alerts or offers"

  def self.address_ready?(event)
    event.organization.reload.marketing_postal_address_ready?
  end

  def self.ensure_address!(event)
    raise AddressMissing, ADDRESS_ERROR unless address_ready?(event)
  end

  class AddressMissing < StandardError; end

  def self.reconcile_failure!(delivery)
    return unless %w[waitlist_notification waitlist_offer].include?(delivery.template)
    return unless delivery.suppressed? || delivery.failed?

    reason = delivery.last_error.presence || "Email delivery failed"
    if delivery.template == "waitlist_offer"
      return if delivery.failed? && delivery.provider_outcome_unknown?

      offer = WaitlistOffer.find_by(id: delivery.metadata["waitlist_offer_id"])
      return unless offer

      offer.waitlist_entry.with_lock do
        next unless offer.reload.offered? && offer.order_id.nil?

        offer.update!(status: :cancelled, token_version: offer.token_version + 1, cancel_reason: reason)
        offer.waitlist_entry.update!(status: :waiting, expires_at: nil, delivery_failure: reason) if offer.waitlist_entry.offered?
      end
    else
      entry = WaitlistEntry.find_by(id: delivery.metadata["waitlist_entry_id"])
      return unless entry

      entry.with_lock do
        next unless entry.notified?
        same_attempt = if delivery.metadata["notified_at"].present?
          entry.notified_at&.iso8601(6) == delivery.metadata["notified_at"]
        else
          entry.notified_at.present? && delivery.created_at >= entry.notified_at
        end
        next unless same_attempt

        entry.update!(status: :waiting, expires_at: nil, delivery_failure: reason)
      end
    end
  end
end
