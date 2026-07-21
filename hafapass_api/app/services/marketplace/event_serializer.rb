# frozen_string_literal: true

module Marketplace
  class EventSerializer
    def self.call(event)
      new(event).call
    end

    def initialize(event)
      @event = event
    end

    def call
      {
        id: event.id,
        title: event.title,
        slug: event.slug,
        short_description: event.short_description,
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
        ticket_types: event.ticket_types.order(:sort_order, :id).map { |type| ticket_type_json(type) },
        purchasable: event.sales_open? && event.has_available_inventory?
      }
    end

    private

    attr_reader :event

    def ticket_type_json(type)
      {
        id: type.id,
        name: type.name,
        current_price_cents: type.current_price_cents,
        price_cents: type.price_cents,
        quantity_remaining: type.available_quantity,
        on_sale: event.sales_open? && type.on_sale?
      }
    end
  end
end
