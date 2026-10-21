# frozen_string_literal: true

module Commerce
  # The one place the per-ticket service fee is calculated. Checkout
  # (OrderCreator) and every public price display use it, so the all-in price
  # a buyer sees first is exactly what checkout charges (FTC 16 CFR Part 464).
  #
  # The fee is rounded per ticket: percent of the unit price, rounded to the
  # cent, plus the flat fee for each paid ticket. The event's fee policy then
  # decides the buyer's share (rounded per ticket); the organizer absorbs the
  # rest. Free tickets carry no fee. Because every amount is per ticket, an
  # order's fee is the sum of its tickets' fees and the advertised all-in
  # price times the quantity always equals the checkout total.
  class ServiceFee
    # Recorded on each order's platform fee component so later readers know
    # which rounding produced it. Orders created before this rounding carry no
    # marker and keep their stored (cart-rounded) amounts.
    ROUNDING = "per_ticket"

    Quote = Data.define(:unit_price_cents, :platform_fee_cents, :buyer_fee_cents, :organizer_fee_cents) do
      def all_in_price_cents
        unit_price_cents + buyer_fee_cents
      end

      def as_json(*)
        {
          all_in_price_cents: all_in_price_cents,
          service_fee_cents: buyer_fee_cents
        }
      end
    end

    Terms = Data.define(:percent, :flat_cents)

    def self.terms(settings = SiteSetting.instance)
      Terms.new(percent: settings.service_fee_percent.to_d, flat_cents: settings.service_fee_flat_cents.to_i)
    end

    def self.quote(unit_price_cents:, buyer_fee_percent:, terms:)
      unit_price_cents = unit_price_cents.to_i
      return Quote.new(unit_price_cents: unit_price_cents, platform_fee_cents: 0, buyer_fee_cents: 0, organizer_fee_cents: 0) unless unit_price_cents.positive?

      platform_fee = (unit_price_cents * terms.percent / 100).round(half: :up).to_i + terms.flat_cents
      buyer_fee = (platform_fee * buyer_fee_percent.to_i / 100r).round(half: :up).to_i
      Quote.new(unit_price_cents: unit_price_cents, platform_fee_cents: platform_fee, buyer_fee_cents: buyer_fee,
        organizer_fee_cents: platform_fee - buyer_fee)
    end

    def self.for_event(event, unit_price_cents, terms: self.terms)
      quote(unit_price_cents: unit_price_cents, buyer_fee_percent: event.buyer_fee_percent, terms: terms)
    end
  end
end
