class Api::V1::TicketsController < ApplicationController
  skip_before_action :authenticate_user!

  def show
    ticket = find_ticket
    return render_not_found unless ticket
    return render_not_found unless ticket.order.ticket_record_available?

    render json: ticket_json(ticket)
  end

  def download
    ticket = find_ticket
    return render_not_found unless ticket
    return render_not_found unless downloadable?(ticket)

    pdf_data = TicketPdfGenerator.new(ticket).generate
    filename = "hafapass-ticket-#{ticket.id}.pdf"

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
    ticket = TicketCredential.find_display(params[:credential] || params[:qr_code])
    Ticket.includes(:order, :ticket_type, :event).find_by(id: ticket&.id)
  end

  def render_not_found
    render json: { error: "Ticket not found" }, status: :not_found
  end

  def downloadable?(ticket)
    ticket.issued? && ticket.order.ticket_fulfilled? && !ticket.order.ticket_access_blocked?
  end

  def ticket_json(ticket)
    {
      id: ticket.id,
      scan_credential: downloadable?(ticket) ? ticket.scan_credential : nil,
      status: ticket.status,
      checked_in_at: ticket.checked_in_at,
      admission_allowed: ticket.admission_allowed?,
      admission_block_reason: ticket.order.ticket_access_blocked? ? "Payment dispute under review" : nil,
      event: {
        id: ticket.event.id,
        title: ticket.event.title,
        slug: ticket.event.slug,
        status: ticket.event.status,
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
