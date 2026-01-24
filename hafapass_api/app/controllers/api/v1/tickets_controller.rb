class Api::V1::TicketsController < ApplicationController
  skip_before_action :authenticate_user!

  def show
    ticket = Ticket.includes(:ticket_type, :event).find_by(qr_code: params[:qr_code])

    unless ticket
      render json: { error: "Ticket not found" }, status: :not_found
      return
    end

    render json: ticket_json(ticket)
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
        venue_address: ticket.event.venue_address,
        starts_at: ticket.event.starts_at,
        ends_at: ticket.event.ends_at,
        doors_open_at: ticket.event.doors_open_at,
        timezone: ticket.event.timezone,
        cover_image_url: ticket.event.cover_image_url
      },
      ticket_type: {
        id: ticket.ticket_type.id,
        name: ticket.ticket_type.name,
        description: ticket.ticket_type.description,
        price_cents: ticket.ticket_type.price_cents
      }
    }
  end
end
