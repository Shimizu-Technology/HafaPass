class Api::V1::Me::TicketsController < ApplicationController
  include Paginatable

  def index
    owned_parent_ids = Ticket.where(holder_user: current_user, parent_ticket_id: nil).select(:id)
    tickets = Ticket
      .where(holder_user: current_user)
      .where("tickets.parent_ticket_id IS NULL OR tickets.parent_ticket_id NOT IN (?)", owned_parent_ids)
      .includes(
        :ticket_type, :event, :order, :ticket_transfers, :parent_ticket,
        :inventory_retention, :pending_refund_tickets,
        child_tickets: [
          :event, :order, :ticket_type, :inventory_retention, :pending_refund_tickets,
          { parent_ticket: :pending_refund_tickets }
        ]
      )
      .order(created_at: :desc, id: :desc)

    pagy, paginated_tickets = paginate(tickets)

    render json: {
      tickets: paginated_tickets.map { |ticket| ticket_json(ticket) },
      meta: pagination_meta(pagy)
    }
  end

  private

  def ticket_json(ticket)
    json = {
      id: ticket.id,
      display_credential: ticket.display_credential,
      status: ticket.status,
      attendee_name: ticket.attendee_name,
      checked_in_at: ticket.checked_in_at,
      admission_allowed: ticket.admission_allowed?,
      pending_transfer: ticket.issued? ? ticket.pending_transfer_summary : nil,
      event: {
        id: ticket.event.id,
        title: ticket.event.title,
        slug: ticket.event.slug,
        status: ticket.event.status,
        venue_name: ticket.event.venue_name,
        starts_at: ticket.event.starts_at,
        ends_at: ticket.event.ends_at,
        timezone: ticket.event.timezone,
        transfers_enabled: ticket.event.transfers_available?,
        cover_image_url: ticket.event.cover_image_url,
        image_asset_host: S3Service.public_asset_host
      },
      ticket_type: {
        id: ticket.ticket_type.id,
        name: ticket.ticket_type.name,
        price_cents: ticket.ticket_type.price_cents
      },
      order_id: ticket.order_id
    }

    if ticket.pass_parent?
      owned_children = ticket.child_tickets.select { |child| child.holder_user_id == current_user.id }
      sorted_children = Passes::TicketPayload.sort_children(owned_children)
      json.merge!(
        is_pass: true,
        pass_parent: true,
        pass_child: false,
        pass_nights_count: sorted_children.size,
        child_tickets: sorted_children.map { |child|
          Passes::TicketPayload.child_json(child, expose_credential: true)
        }
      )
    end

    json
  end
end
