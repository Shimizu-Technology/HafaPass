# frozen_string_literal: true

module Marketplace
  class EventSerializer
    def self.call(event, purchasable: nil, fee_terms: nil, locale: AppLocale::DEFAULT)
      new(event, purchasable: purchasable, fee_terms: fee_terms, locale: locale).call
    end

    def initialize(event, purchasable:, fee_terms: nil, locale: AppLocale::DEFAULT)
      @event = event
      @locale = locale
      @purchasable = purchasable
      @fee_terms = fee_terms
    end

    def call
      content = event.content_for(@locale)
      {
        id: event.id,
        title: content[:title],
        slug: event.slug,
        short_description: content[:short_description],
        content_locale: content[:locale],
        machine_translated: content[:machine_translated],
        original_content: content[:locale] == AppLocale::DEFAULT ? nil : event.slice(*Event::CONTENT_FIELDS),
        cover_image_url: event.cover_image_url,
        starts_at: event.starts_at,
        ends_at: event.ends_at,
        timezone: event.timezone,
        category: event.category,
        category_label: event.category_label,
        venue_name: event.venue_name,
        venue_city: event.venue_city,
        venue: event.venue && { name: event.venue.name, slug: event.venue.slug, village: event.venue.village },
        organizer: {
          name: event.organizer_profile.business_name,
          slug: event.organization.slug,
          verified: event.organizer_profile.verification_status_verified?
        },
        ticket_types: ordered_ticket_types.map { |type| ticket_type_json(type) },
        purchasable: purchasable.nil? ? event.sales_open? && event.has_available_inventory? : purchasable
      }
    end

    private

    attr_reader :event, :purchasable

    def fee_terms
      @fee_terms ||= Commerce::ServiceFee.terms
    end

    def ordered_ticket_types
      return event.ticket_types.sort_by { |type| [type.sort_order || 0, type.id] } if event.ticket_types.loaded?

      event.ticket_types.order(:sort_order, :id)
    end

    def ticket_type_json(type)
      content = type.content_for(@locale)
      current_price_cents = type.current_price_cents
      fee = Commerce::ServiceFee.for_event(event, current_price_cents, terms: fee_terms)
      {
        id: type.id,
        name: content[:name],
        description: content[:description],
        machine_translated: content[:machine_translated],
        original_name: type.name,
        original_description: type.description,
        current_price_cents: current_price_cents,
        all_in_price_cents: fee.all_in_price_cents,
        service_fee_cents: fee.buyer_fee_cents,
        price_cents: type.price_cents,
        quantity_remaining: type.available_quantity,
        on_sale: event.sales_open? && type.on_sale?
      }
    end
  end
end
