# frozen_string_literal: true

module Seating
  class ConfigurationActivator
    class ConfigurationError < StandardError; end

    def self.call(**)
      new(**).call
    end

    def initialize(event:, venue_layout:, zone_ticket_types:, actor:)
      @event = event
      @venue_layout = venue_layout
      @zone_ticket_types = zone_ticket_types.to_h.transform_keys(&:to_i).transform_values(&:to_i)
      @actor = actor
    end

    def call
      EventSeatingConfiguration.transaction do
        event.lock!
        validate_configuration!
        existing = event.event_seating_configuration
        if existing && (existing.event_seats.joins(:tickets).exists? || existing.seat_hold_sessions.where(status: [:active, :claimed]).exists?)
          raise ConfigurationError, "A seating configuration with sales or active holds cannot be replaced"
        end
        if existing
          existing.event_seats.destroy_all
          existing.destroy!
        end

        configuration = event.create_event_seating_configuration!(venue_layout: venue_layout, status: :draft)
        layout_zone_ids = venue_layout.seating_price_zones.pluck(:id).sort
        unless zone_ticket_types.keys.sort == layout_zone_ids
          raise ConfigurationError, "Map every layout price zone to a ticket type"
        end
        zones = venue_layout.seating_price_zones.where(id: layout_zone_ids).index_by(&:id)

        ticket_types = event.ticket_types.where(id: zone_ticket_types.values).index_by(&:id)
        raise ConfigurationError, "Every mapped ticket type must belong to this event" unless ticket_types.length == zone_ticket_types.values.uniq.length

        zone_ticket_types.each do |zone_id, ticket_type_id|
          configuration.event_price_zones.create!(seating_price_zone: zones.fetch(zone_id), ticket_type: ticket_types.fetch(ticket_type_id))
        end
        create_event_seats!(configuration)
        synchronize_inventory!(configuration, ticket_types)
        configuration.update!(status: :active, activated_at: Time.current)
        Audit.record!(event: event, action: "seating.configuration_activated", actor: actor,
          metadata: { venue_layout_id: venue_layout.id, event_seat_count: configuration.event_seats.count })
        configuration
      end
    rescue ActiveRecord::RecordInvalid => e
      raise ConfigurationError, e.record.errors.full_messages.to_sentence
    end

    private

    attr_reader :event, :venue_layout, :zone_ticket_types, :actor

    def validate_configuration!
      raise ConfigurationError, "Publish the venue layout before activating it" unless venue_layout.status_published?
      unless event.venue_id == venue_layout.venue_id && event.organization_id == venue_layout.organization_id
        raise ConfigurationError, "The layout must belong to this event's venue and organization"
      end
      raise ConfigurationError, "A venue layout needs at least one active seat" unless venue_layout.venue_seats.where(active: true).exists?
    end

    def create_event_seats!(configuration)
      mappings = configuration.event_price_zones.index_by(&:seating_price_zone_id)
      venue_layout.venue_seats.where(active: true).order(:id).find_each do |seat|
        mapping = mappings.fetch(seat.seating_price_zone_id)
        configuration.event_seats.create!(venue_seat: seat, ticket_type: mapping.ticket_type)
      end
    end

    def synchronize_inventory!(configuration, ticket_types)
      counts = configuration.event_seats.group(:ticket_type_id).count
      total = counts.values.sum
      if event.max_capacity.present? && event.max_capacity < total
        raise ConfigurationError, "Event capacity must cover all assigned seats"
      end
      ticket_types.each_value do |ticket_type|
        count = counts.fetch(ticket_type.id, 0)
        raise ConfigurationError, "Every mapped ticket type needs at least one seat" unless count.positive?
        raise ConfigurationError, "Seat inventory cannot be lower than tickets already sold" if count < ticket_type.quantity_sold

        ticket_type.update!(quantity_available: count)
      end
    end
  end
end
