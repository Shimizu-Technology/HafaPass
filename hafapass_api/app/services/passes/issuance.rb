# frozen_string_literal: true

module Passes
  class Issuance
    def self.call(order:, parent_ticket:, included_events: nil)
      new(order: order, parent_ticket: parent_ticket, included_events: included_events).call
    end

    def initialize(order:, parent_ticket:, included_events: nil)
      @order = order
      @parent_ticket = parent_ticket
      @included_events = included_events
    end

    def call
      return [] unless parent_ticket.pass_parent?

      events = resolve_included_events
      return [] if events.empty?

      existing_event_ids = Ticket.where(parent_ticket_id: parent_ticket.id, event_id: events.map(&:id))
        .pluck(:event_id)
        .to_set

      created = []
      events.each do |included_event|
        next if existing_event_ids.include?(included_event.id)

        child = order.tickets.create!(
          event: included_event,
          ticket_type: parent_ticket.ticket_type,
          order_item: nil,
          parent_ticket: parent_ticket,
          attendee_name: parent_ticket.attendee_name,
          attendee_email: parent_ticket.attendee_email,
          holder_user: parent_ticket.holder_user,
          holder_email: parent_ticket.holder_email
        )
        child.issue_qr_code!
        created << child
      end
      created
    end

    private

    attr_reader :order, :parent_ticket, :included_events

    def resolve_included_events
      return Array(included_events) unless included_events.nil?

      parent_ticket.ticket_type.ticket_type_included_events.includes(:included_event).map(&:included_event)
    end
  end
end
