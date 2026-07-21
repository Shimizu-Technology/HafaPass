# frozen_string_literal: true

module WaitlistOffers
  class Issuer
    OFFER_DURATION = 30.minutes

    class OfferError < StandardError; end

    def self.call(entry:, ticket_type: nil)
      new(entry: entry, ticket_type: ticket_type).call
    end

    def initialize(entry:, ticket_type: nil)
      @entry = entry
      @ticket_type = ticket_type
    end

    def call
      offer = nil
      Event.transaction do
        entry.event.lock!
        entry.lock!
        raise OfferError, "Only waiting entries can receive an offer" unless entry.waiting?

        selected = select_ticket_type
        selected.lock!
        quantity = [entry.quantity, selected.available_quantity, entry.event.remaining_capacity].min
        raise OfferError, "No inventory is available for this waitlist entry" unless quantity.positive?

        tier = selected.active_pricing_tier
        tier&.lock!
        offer = entry.waitlist_offers.create!(
          event: entry.event,
          ticket_type: selected,
          pricing_tier: tier,
          quantity: quantity,
          unit_price_cents: tier&.price_cents || selected.price_cents,
          expires_at: OFFER_DURATION.from_now
        )
        entry.update!(status: :offered, notified_at: Time.current, expires_at: offer.expires_at)
      end
      EmailService.send_waitlist_offer_async(offer)
      offer
    rescue ActiveRecord::RecordNotUnique
      raise OfferError, "This waitlist entry already has an active offer"
    end

    private

    attr_reader :entry, :ticket_type

    def select_ticket_type
      selected = ticket_type || entry.ticket_type || entry.event.ticket_types.order(:id).find(&:available_quantity&.positive?)
      unless selected&.event_id == entry.event_id
        raise OfferError, "Ticket type is not available for this waitlist entry"
      end

      selected
    end
  end
end
