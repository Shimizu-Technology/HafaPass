# frozen_string_literal: true

class EventCapacity
  class << self
    def committed_for(event, at: Time.current)
      direct_sold(event) +
        direct_holds(event, at: at) +
        direct_waitlist_offers(event, at: at) +
        direct_seat_holds(event, at: at) +
        pass_child_tickets(event) +
        pass_holds_targeting(event, at: at)
    end

    def remaining_for(event, at: Time.current)
      return Float::INFINITY if event.max_capacity.blank?

      [event.max_capacity - committed_for(event, at: at), 0].max
    end

    def pass_committed_for(event, at: Time.current)
      return 0 unless event.persisted?
      return 0 if event.pass_inclusions.loaded? && event.pass_inclusions.empty?

      pass_child_tickets(event) + pass_holds_targeting(event, at: at)
    end

    def pass_committed_by_event_ids(event_ids, at: Time.current)
      ids = Array(event_ids).compact.uniq
      return {} if ids.empty?

      child_counts = Ticket.where(event_id: ids).where.not(parent_ticket_id: nil).where.not(status: :cancelled)
        .group(:event_id).count
      hold_counts = InventoryHold.active
        .where("inventory_holds.expires_at > ?", at)
        .joins("INNER JOIN ticket_type_included_events ON ticket_type_included_events.ticket_type_id = inventory_holds.ticket_type_id")
        .where(ticket_type_included_events: { included_event_id: ids })
        .group("ticket_type_included_events.included_event_id")
        .sum(:quantity)

      ids.index_with { |id| child_counts.fetch(id, 0) + hold_counts.fetch(id, 0) }
    end

    def direct_sold(event)
      event.persisted? ? event.ticket_types.sum(:quantity_sold) : event.ticket_types.sum(&:quantity_sold)
    end

    def direct_holds(event, at: Time.current)
      return 0 unless event.persisted?

      event.inventory_holds.active.where("inventory_holds.expires_at > ?", at).sum(:quantity)
    end

    def direct_waitlist_offers(event, at: Time.current)
      return 0 unless event.persisted?

      event.waitlist_offers.holding_inventory(at).sum(:quantity)
    end

    def direct_seat_holds(event, at: Time.current)
      return 0 unless event.persisted? && event.event_seating_configuration

      SeatHold.status_active.joins(:seat_hold_session, :event_seat)
        .where(event_seats: { event_seating_configuration_id: event.event_seating_configuration.id })
        .where(seat_hold_sessions: { status: SeatHoldSession.statuses[:active] })
        .where("seat_hold_sessions.expires_at > ?", at).count
    end

    def pass_child_tickets(event)
      return 0 unless event.persisted?

      Ticket.where(event_id: event.id).where.not(parent_ticket_id: nil).where.not(status: :cancelled).count
    end

    def pass_holds_targeting(event, at: Time.current)
      return 0 unless event.persisted?

      InventoryHold.active
        .where("inventory_holds.expires_at > ?", at)
        .joins("INNER JOIN ticket_type_included_events ON ticket_type_included_events.ticket_type_id = inventory_holds.ticket_type_id")
        .where(ticket_type_included_events: { included_event_id: event.id })
        .sum(:quantity)
    end
  end
end
