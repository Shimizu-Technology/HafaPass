class Api::V1::TicketsController < ApplicationController
  skip_before_action :authenticate_user!
  before_action :optional_authenticate_user!

  def show
    ticket = find_ticket
    return render_not_found unless ticket
    return render_not_found unless ticket.order.ticket_record_available?

    render json: ticket_json(ticket)
  end

  def download
    ticket = find_ticket
    return render_not_found unless ticket
    return render_not_found unless downloadable?(ticket) && admission_access?(ticket)

    pdf_data = TicketPdfGenerator.new(ticket).generate
    filename = "hafapass-ticket-#{ticket.id}.pdf"

    send_data pdf_data,
              filename: filename,
              type: "application/pdf",
              disposition: "attachment"
  end

  def apple_wallet
    ticket = find_ticket
    return render_not_found unless ticket && downloadable?(ticket) && admission_access?(ticket)

    send_data Wallet::ApplePassGenerator.call(ticket), filename: "hafapass-ticket-#{ticket.id}.pkpass",
      type: "application/vnd.apple.pkpass", disposition: "attachment"
  rescue Wallet::ApplePassGenerator::ConfigurationError => e
    render json: { error: e.message }, status: :service_unavailable
  end

  def google_wallet
    ticket = find_ticket
    return render_not_found unless ticket && downloadable?(ticket) && admission_access?(ticket)

    url = Wallet::GoogleSaveLink.call(ticket)
    return render json: { url: url } if params[:response] == "json"

    redirect_to url, allow_other_host: true
  rescue Wallet::GoogleSaveLink::ConfigurationError => e
    render json: { error: e.message }, status: :service_unavailable
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
      scan_credential: downloadable?(ticket) && admission_access?(ticket) ? ticket.scan_credential : nil,
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

  def admission_access?(ticket)
    return true if @current_user&.admin?
    return ticket.held_by?(@current_user) if ticket.holder_user_id.present?
    return true if ticket.order.user_id.present? && ticket.order.user_id == @current_user&.id

    token = request.headers["X-Guest-Order-Token"].presence
    token.present? && GuestOrderAccess.find(token)&.id == ticket.order_id
  end
end
