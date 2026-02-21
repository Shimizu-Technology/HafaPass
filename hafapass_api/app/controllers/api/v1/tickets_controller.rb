class Api::V1::TicketsController < ApplicationController
  skip_before_action :authenticate_user!

  def show
    ticket = find_ticket
    return render_not_found unless ticket

    render json: ticket_json(ticket)
  end

  def download
    ticket = find_ticket
    return render_not_found unless ticket

    pdf_data = TicketPdfGenerator.new(ticket).generate
    filename = "hafapass-ticket-#{ticket.qr_code[0..7]}.pdf"

    send_data pdf_data,
              filename: filename,
              type: "application/pdf",
              disposition: "attachment"
  end

  def apple_wallet
    render json: {
      error: "Coming soon! Add to home screen for now.",
      status: "not_implemented"
    }, status: :not_implemented
  end

  def google_wallet
    render json: {
      error: "Coming soon! Add to home screen for now.",
      status: "not_implemented"
    }, status: :not_implemented
  end

  private

  def find_ticket
    Ticket.includes(:ticket_type, :event).find_by(qr_code: params[:qr_code])
  end

  def render_not_found
    render json: { error: "Ticket not found" }, status: :not_found
  end

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
