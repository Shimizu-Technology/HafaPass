# frozen_string_literal: true

module Seating
  class MapPresenter
    def self.call(configuration, at: Time.current)
      new(configuration, at: at).call
    end

    def initialize(configuration, at:)
      @configuration = configuration
      @at = at
    end

    def call
      configuration.event_seats.includes(
        :active_tickets,
        :blocking_seat_holds,
        ticket_type: [
          :inventory_holds,
          :waitlist_offers,
          { event_seats: :active_precheckout_seat_holds },
          { pricing_tiers: [:inventory_holds, :waitlist_offers, :active_precheckout_seat_holds] }
        ],
        venue_seat: [:seating_price_zone, { seating_row: :seating_section }]
      ).then do |event_seats|
        {
          event_id: configuration.event_id,
          configuration_id: configuration.id,
          renderer: configuration.venue_layout.renderer,
          provider_chart_key: configuration.venue_layout.provider_chart_key,
          suspended: configuration.event.sales_suspended_at.present?,
          suspension_reason: configuration.event.sales_suspension_reason,
          hold_duration_seconds: HoldAllocator::HOLD_DURATION.to_i,
          sections: grouped_sections(event_seats)
        }
      end
    end

    private

    attr_reader :configuration, :at

    def grouped_sections(event_seats)
      event_seats.group_by { |seat| seat.venue_seat.seating_row.seating_section }
        .sort_by { |section, _| [section.position, section.id] }
        .map do |section, section_seats|
          {
            id: section.id,
            name: section.name,
            code: section.code,
            rows: grouped_rows(section_seats)
          }
        end
    end

    def grouped_rows(event_seats)
      event_seats.group_by { |seat| seat.venue_seat.seating_row }
        .sort_by { |row, _| [row.position, row.id] }
        .map do |row, row_seats|
          {
            id: row.id,
            label: row.label,
            seats: row_seats.sort_by { |seat| [seat.venue_seat.position, seat.id] }.map { |seat| seat_json(seat) }
          }
        end
    end

    def seat_json(seat)
      venue_seat = seat.venue_seat
      released = seat.generally_released?(at: at)
      {
        id: seat.id,
        label: venue_seat.label,
        display_label: venue_seat.display_label,
        price_cents: seat.ticket_type.current_price_cents(at: at),
        ticket_type_id: seat.ticket_type_id,
        ticket_type_name: seat.ticket_type.name,
        price_zone: {
          id: venue_seat.seating_price_zone_id,
          name: venue_seat.seating_price_zone.name,
          color: venue_seat.seating_price_zone.color
        },
        accessibility_kind: venue_seat.accessibility_kind,
        companion_group: venue_seat.companion_group,
        requires_accessibility_attestation: seat.accessible_inventory? && !released,
        generally_released: released,
        obstructed_view: venue_seat.obstructed_view,
        view_note: venue_seat.view_note,
        status: public_status(seat)
      }
    end

    def public_status(seat)
      return "unavailable" unless seat.operational_status_available?
      return "sold" if seat.active_tickets.any?

      blocking = seat.blocking_seat_holds.any?
      blocking ? "held" : "available"
    end
  end
end
