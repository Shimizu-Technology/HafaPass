class Api::V1::Me::TicketsController < ApplicationController
  def index
    tickets = Ticket
      .joins(:order)
      .where(orders: { user_id: current_user.id })
      .includes(:ticket_type, :event, :order)
      .order(created_at: :desc)

    render json: tickets.map { |ticket| ticket_json(ticket) }
  end

  private

  def ticket_json(ticket)
    {
      id: ticket.id,
      qr_code: ticket.qr_code,
      status: ticket.status,
      attendee_name: ticket.attendee_name,
      attendee_email: ticket.attendee_email,
      checked_in_at: ticket.checked_in_at,
      event: {
        id: ticket.event.id,
        title: ticket.event.title,
        slug: ticket.event.slug,
        venue_name: ticket.event.venue_name,
        starts_at: ticket.event.starts_at,
        ends_at: ticket.event.ends_at,
        cover_image_url: ticket.event.cover_image_url
      },
      ticket_type: {
        id: ticket.ticket_type.id,
        name: ticket.ticket_type.name,
        price_cents: ticket.ticket_type.price_cents
      },
      order_id: ticket.order_id
    }
  end
end
