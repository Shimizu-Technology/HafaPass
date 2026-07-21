# frozen_string_literal: true

module Seating
  class AccessibleRelease
    class ReleaseError < StandardError; end

    def self.call(**)
      new(**).call
    end

    def initialize(event:, event_seats:, actor:, reason:, at: Time.current)
      @event = event
      @event_seats = event_seats
      @actor = actor
      @reason = reason.to_s.strip
      @at = at
    end

    def call
      raise ReleaseError, "A release reason is required" if reason.blank?

      releases = []
      EventSeat.transaction do
        seats = event.event_seating_configuration.event_seats.where(id: event_seats.map(&:id)).order(:id).lock.to_a
        raise ReleaseError, "Select accessible or companion inventory" if seats.empty?

        seats.each do |seat|
          raise ReleaseError, "Only protected accessible inventory can be released" unless seat.accessible_inventory?
          raise ReleaseError, "The seat is not available for release" unless seat.selectable?(at: at)

          scope, evidence = qualifying_scope(seat)
          unless scope
            raise ReleaseError,
              "Accessible seats may be released only after non-accessible seats sell out in the venue, section, or price zone"
          end
          seat.update!(general_release_at: at)
          releases << AccessibleSeatRelease.create!(
            event_seat: seat,
            released_by_user: actor,
            release_scope: scope,
            reason: reason,
            evidence: evidence,
            released_at: at
          )
          Audit.record!(event: event, action: "accessible_seat.released", event_seat: seat, actor: actor,
            metadata: evidence.merge(scope: scope, reason: reason))
        end
      end
      releases
    rescue ActiveRecord::RecordNotUnique
      raise ReleaseError, "A selected seat has already been released"
    end

    private

    attr_reader :event, :event_seats, :actor, :reason, :at

    def qualifying_scope(seat)
      standards = standard_event_seats
      section_id = seat.venue_seat.seating_row.seating_section_id
      section = standards.select { |candidate| candidate.venue_seat.seating_row.seating_section_id == section_id }
      zone = standards.select { |candidate| candidate.venue_seat.seating_price_zone_id == seat.venue_seat.seating_price_zone_id }
      venue = standards

      return scope_result("section", section) if sold_out?(section)
      return scope_result("price_zone", zone) if sold_out?(zone)
      return scope_result("venue", venue) if sold_out?(venue)

      [nil, {}]
    end

    def standard_event_seats
      @standard_event_seats ||= event.event_seating_configuration.event_seats
        .includes(:active_tickets, venue_seat: { seating_row: :seating_section })
        .select { |candidate| candidate.venue_seat.accessibility_kind_standard? }
    end

    def sold_out?(seats)
      seats.any? && seats.all? do |seat|
        seat.active_tickets.any?
      end
    end

    def scope_result(scope, seats)
      [scope, { evaluated_standard_seat_ids: seats.map(&:id), evaluated_at: at.iso8601 }]
    end
  end
end
