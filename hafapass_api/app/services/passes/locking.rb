# frozen_string_literal: true

module Passes
  class Locking
    class LockSetChanged < StandardError; end

    MAX_LOCK_RETRIES = 2

    class << self
      def with_lock_retry(max_retries: MAX_LOCK_RETRIES)
        attempts = 0
        begin
          yield
        rescue LockSetChanged
          raise if attempts >= max_retries || inside_application_transaction?

          attempts += 1
          retry
        end
      end

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
        ticket_type_ids = extract_ticket_type_ids(line_items)
        included = included_events_for_ticket_type_ids(event: event, ticket_type_ids: ticket_type_ids)
        locked = lock_events!([event, *included])
        if ticket_type_ids.any?
          locked_ids = locked.map(&:id)
          rechecked_ids = included_event_ids_for_ticket_type_ids(event: event, ticket_type_ids: ticket_type_ids)
          if (rechecked_ids - locked_ids).any?
            raise LockSetChanged, "Pass included events changed while acquiring event locks"
          end
        end
        locked
      end

      def lock_events_for_order!(order)
        pass_tt_ids = TicketType.where(event_id: order.event_id, is_pass: true).pluck(:id)
        return lock_events!([order.event]) if pass_tt_ids.empty?

        order_pass_tt_ids = order_pass_ticket_type_ids(order, pass_tt_ids)
        return lock_events!([order.event]) if order_pass_tt_ids.empty?

        other_event_ids = related_event_ids_for_pass_order(order, order_pass_tt_ids) - [order.event_id]
        other_events = other_event_ids.any? ? Event.where(id: other_event_ids).to_a : []
        locked = lock_events!([order.event, *other_events])

        locked_ids = locked.map(&:id)
        rechecked_ids = related_event_ids_for_pass_order(order, order_pass_tt_ids)
        if (rechecked_ids - locked_ids).any?
          raise LockSetChanged, "Pass included events changed while acquiring event locks"
        end

        locked
      end

      def lock_events_for_included_event!(event)
        linked_ids = linked_pass_event_ids(event)
        linked_events = linked_ids.any? ? Event.where(id: linked_ids).to_a : []
        locked = lock_events!([event, *linked_events])

        locked_ids = locked.map(&:id)
        rechecked_ids = linked_pass_event_ids(event)
        if (rechecked_ids - locked_ids).any?
          raise LockSetChanged, "Linked pass events changed while acquiring event locks"
        end

        locked
      end

      def linked_pass_event_ids(event)
        TicketType
          .joins(:ticket_type_included_events)
          .where(ticket_type_included_events: { included_event_id: event.id })
          .distinct
          .pluck(:event_id)
      end

      def included_events_for_line_items(event:, line_items:)
        ticket_type_ids = extract_ticket_type_ids(line_items)
        included_events_for_ticket_type_ids(event: event, ticket_type_ids: ticket_type_ids)
      end

      def related_event_ids_for_order(order)
        pass_tt_ids = TicketType.where(event_id: order.event_id, is_pass: true).pluck(:id)
        return [] if pass_tt_ids.empty?

        order_pass_tt_ids = order_pass_ticket_type_ids(order, pass_tt_ids)
        return [] if order_pass_tt_ids.empty?

        related_event_ids_for_pass_order(order, order_pass_tt_ids)
      end

      private

      def inside_application_transaction?
        ActiveRecord::Base.connection.current_transaction.joinable?
      end

      def extract_ticket_type_ids(line_items)
        return [] unless line_items.is_a?(Array) && line_items.any?

        line_items.filter_map do |item|
          next unless item.is_a?(Hash) || item.respond_to?(:[])

          (item[:ticket_type_id] || item["ticket_type_id"]).to_i
        end.select(&:positive?).uniq
      end

      def included_event_ids_for_ticket_type_ids(event:, ticket_type_ids:)
        return [] if ticket_type_ids.empty?

        TicketTypeIncludedEvent
          .joins(:ticket_type)
          .where(ticket_type_id: ticket_type_ids, ticket_types: { event_id: event.id })
          .distinct
          .pluck(:included_event_id)
      end

      def included_events_for_ticket_type_ids(event:, ticket_type_ids:)
        included_ids = included_event_ids_for_ticket_type_ids(event: event, ticket_type_ids: ticket_type_ids)
        return [] if included_ids.empty?

        Event.where(id: included_ids).to_a
      end

      def order_pass_ticket_type_ids(order, pass_tt_ids)
        (
          order.order_items.where(ticket_type_id: pass_tt_ids).pluck(:ticket_type_id) +
          order.inventory_holds.where(ticket_type_id: pass_tt_ids).pluck(:ticket_type_id) +
          order.tickets.where(ticket_type_id: pass_tt_ids).pluck(:ticket_type_id)
        ).compact.uniq
      end

      def related_event_ids_for_pass_order(order, order_pass_tt_ids)
        included_ids = TicketTypeIncludedEvent
          .where(ticket_type_id: order_pass_tt_ids)
          .distinct
          .pluck(:included_event_id)
        ticket_event_ids = order.tickets.where.not(event_id: order.event_id).distinct.pluck(:event_id)
        (included_ids + ticket_event_ids).compact.uniq
      end
    end
  end
end
