# frozen_string_literal: true

module Passes
  class Locking
    class << self
      # Acquires Rank 2 event locks in deterministic ascending event.id order
      # using FOR NO KEY UPDATE so concurrent multi-night pass and single-night
      # transactions never cycle.
      def lock_events!(events)
        unique_events = {}
        Array(events).compact.each do |ev|
          unique_events[ev.id] ||= ev
        end
        ordered = unique_events.values.sort_by(&:id)
        ordered.each { |ev| ev.lock!("FOR NO KEY UPDATE") }
        ordered
      end

      def lock_events_for_line_items!(event:, line_items:)
        included = included_events_for_line_items(event: event, line_items: line_items)
        lock_events!([event, *included])
      end

      def lock_events_for_order!(order)
        other_event_ids = related_event_ids_for_order(order) - [order.event_id]
        other_events = other_event_ids.any? ? Event.where(id: other_event_ids).to_a : []
        lock_events!([order.event, *other_events])
      end

      def included_events_for_line_items(event:, line_items:)
        return [] unless line_items.is_a?(Array) && line_items.any?

        ticket_type_ids = line_items.filter_map do |item|
          next unless item.is_a?(Hash) || item.respond_to?(:[])

          (item[:ticket_type_id] || item["ticket_type_id"]).to_i
        end.select(&:positive?).uniq
        return [] if ticket_type_ids.empty?

        included_ids = TicketTypeIncludedEvent
          .joins(:ticket_type)
          .where(ticket_type_id: ticket_type_ids, ticket_types: { event_id: event.id })
          .distinct
          .pluck(:included_event_id)
        return [] if included_ids.empty?

        Event.where(id: included_ids).to_a
      end

      def related_event_ids_for_order(order)
        ticket_type_ids = (
          order.order_items.pluck(:ticket_type_id) +
          order.inventory_holds.pluck(:ticket_type_id) +
          order.tickets.pluck(:ticket_type_id)
        ).compact.uniq

        included_ids = if ticket_type_ids.any?
          TicketTypeIncludedEvent.where(ticket_type_id: ticket_type_ids).distinct.pluck(:included_event_id)
        else
          []
        end

        ticket_event_ids = order.tickets.distinct.pluck(:event_id)
        (included_ids + ticket_event_ids).compact.uniq
      end
    end
  end
end
