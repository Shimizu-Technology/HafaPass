# frozen_string_literal: true

module Passes
  module TicketPayload
    module_function

    def sort_children(children)
      Array(children).sort_by { |child| [child.event&.starts_at || Time.at(0), child.id] }
    end

    def child_admission_block_reason(child)
      return nil if child.cancelled? || child.parent_ticket&.cancelled?
      return "Refunded or disputed admission requires organizer review" if child.inventory_retained? || child.parent_ticket&.inventory_retained?
      return "Payment dispute under review" if child.order.ticket_access_blocked?
      return "Ticket access is paused while its refund is pending" if child.refund_pending?
      return "Event is #{child.event.status}" if child.issued? && child.event && !child.event.published?

      nil
    end

    def child_json(child, expose_credential:, transferred_away: false)
      display_cred = expose_credential && !transferred_away ? child.display_credential : nil
      event = child.event

      {
        id: child.id,
        parent_ticket_id: child.parent_ticket_id,
        status: transferred_away ? "transferred" : child.status,
        checked_in_at: child.checked_in_at,
        admission_allowed: !transferred_away && child.admission_allowed?,
        admission_block_reason: child_admission_block_reason(child),
        display_credential: display_cred,
        display_token: display_cred,
        ticket_url: display_cred ? "/tickets/#{display_cred}" : nil,
        event: {
          id: event.id,
          title: event.title,
          slug: event.slug,
          starts_at: event.starts_at,
          ends_at: event.ends_at,
          timezone: event.timezone,
          status: event.status,
          venue_name: event.venue_name
        }
      }
    end

    def parent_pass_summary(ticket)
      parent = ticket.parent_ticket
      return nil unless parent

      {
        ticket_type_name: ticket.ticket_type.name,
        event_title: parent.event.title,
        event_slug: parent.event.slug,
        nights_count: parent.child_tickets.size
      }
    end

    def included_event_json(event, title: event.title)
      {
        id: event.id,
        title: title,
        slug: event.slug,
        starts_at: event.starts_at,
        ends_at: event.ends_at,
        timezone: event.timezone,
        status: event.status
      }
    end
  end
end
