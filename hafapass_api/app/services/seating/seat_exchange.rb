# frozen_string_literal: true

module Seating
  class SeatExchange
    class ExchangeError < StandardError; end

    def self.call(**)
      new(**).call
    end

    def initialize(ticket:, target_event_seat:, actor:, accessibility_attested:, at: Time.current)
      @ticket = ticket
      @target = target_event_seat
      @actor = actor
      @accessibility_attested = ActiveModel::Type::Boolean.new.cast(accessibility_attested)
      @at = at
    end

    def call
      Ticket.transaction do
        ticket.lock!
        raise ExchangeError, "Only unused active tickets can change seats" unless ticket.issued?
        raise ExchangeError, "This ticket does not have an assigned seat" unless ticket.event_seat

        [ticket.event_seat, target].sort_by(&:id).each(&:lock!)
        validate_target!
        previous = ticket.event_seat
        ticket.update!(
          event_seat: target,
          scan_credential_version: ticket.scan_credential_version + 1,
          display_credential_version: ticket.display_credential_version + 1
        )
        Audit.record!(event: ticket.event, action: "seat.exchanged", event_seat: target, ticket: ticket, actor: actor,
          metadata: { previous_event_seat_id: previous.id, target_event_seat_id: target.id })
        ticket
      end
    rescue ActiveRecord::RecordNotUnique
      raise ExchangeError, "The selected seat is no longer available"
    end

    private

    attr_reader :ticket, :target, :actor, :accessibility_attested, :at

    def validate_target!
      unless target.event_seating_configuration.event_id == ticket.event_id && target.ticket_type_id == ticket.ticket_type_id
        raise ExchangeError, "Choose a seat in the same event and price category"
      end
      raise ExchangeError, "The selected seat is no longer available" unless target.selectable?(at: at)
      if target.accessible_inventory? && !target.generally_released?(at: at) && !accessibility_attested
        raise ExchangeError, "Confirm that accessible seating is needed for this party"
      end
      unless target.accessibility_kind == ticket.event_seat.accessibility_kind
        raise ExchangeError, "Self-service exchanges must keep the same accessibility seat type"
      end
    end
  end
end
