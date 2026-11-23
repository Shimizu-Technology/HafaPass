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
  rescue TicketPdfGenerator::UnsupportedCharacterError
    render json: { error_code: "unsupported_pdf_text",
      error: "This ticket contains text that cannot be printed in the PDF. Use your browser ticket or contact the organizer." },
      status: :unprocessable_entity
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
    Ticket.includes(
      :order, :ticket_type, :event, :inventory_retention, :pending_refund_tickets,
      { parent_ticket: [:event, :child_tickets, :pending_refund_tickets, :inventory_retention] },
      { child_tickets: [:event, :order, :ticket_type, :inventory_retention, :pending_refund_tickets,
        { parent_ticket: [:pending_refund_tickets, :inventory_retention] }] },
      event_seat: { venue_seat: { seating_row: :seating_section } }
    ).find_by(id: ticket&.id)
  end

  def render_not_found
    render json: { error: "Ticket not found" }, status: :not_found
  end

  def downloadable?(ticket)
    ticket.admission_allowed?
  end

  def admission_block_reason(ticket)
    return nil if ticket.cancelled? || (ticket.pass_child? && ticket.parent_ticket&.cancelled?)
    if ticket.inventory_retained? || (ticket.pass_child? && ticket.parent_ticket&.inventory_retained?)
      return "Refunded or disputed admission requires organizer review"
    end
    return "Payment dispute under review" if ticket.order.ticket_access_blocked?
    "Ticket access is paused while its refund is pending" if ticket.refund_pending?
  end

  def ticket_json(ticket)
    json = {
      id: ticket.id,
      scan_credential: downloadable?(ticket) && admission_access?(ticket) ? ticket.scan_credential : nil,
      status: ticket.status,
      checked_in_at: ticket.checked_in_at,
      event_change_refund_contact_support: event_change_refund_contact_support?(ticket),
      admission_allowed: ticket.admission_allowed?,
      wallet_availability: {
        apple: Wallet::ApplePassGenerator.enabled?,
        google: Wallet::GoogleSaveLink.enabled?
      },
      admission_block_reason: admission_block_reason(ticket),
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
        cover_image_url: ticket.event.cover_image_url,
        page_customization: ticket.event.page_customization.is_a?(Hash) ? ticket.event.page_customization.slice("focal_point") : {},
        image_asset_host: S3Service.public_asset_host
      },
      seller: SellerIdentity.for_event(ticket.event).as_json,
      ticket_type: {
        id: ticket.ticket_type.id,
        name: ticket.ticket_type.name,
        description: ticket.ticket_type.description,
        price_cents: ticket.ticket_type.price_cents
      },
      seat: ticket.event_seat && {
        id: ticket.event_seat_id,
        display_label: ticket.seat_label,
        accessibility_kind: ticket.event_seat.accessibility_kind,
        obstructed_view: ticket.event_seat.obstructed_view,
        view_note: ticket.event_seat.view_note
      }
    }

    if ticket.pass_parent?
      sorted_children = Passes::TicketPayload.sort_children(ticket.child_tickets)
      expose_via_parent = parent_display_exposes_children?(ticket)
      json.merge!(
        is_pass: true,
        pass_parent: true,
        pass_child: false,
        pass_nights_count: sorted_children.size,
        child_tickets: sorted_children.map { |child|
          transferred_away = child.transferred? || child.transferred_away_from?(ticket.order)
          Passes::TicketPayload.child_json(
            child,
            expose_credential: !transferred_away && (
              admission_access?(child) ||
              (expose_via_parent && !child.cancelled? && !child.refund_pending? && !child.inventory_retained?)
            ),
            transferred_away: transferred_away
          )
        }
      )
    elsif ticket.pass_child?
      json.merge!(
        is_pass: true,
        pass_parent: false,
        pass_child: true,
        parent_ticket_id: ticket.parent_ticket_id,
        parent_pass: Passes::TicketPayload.parent_pass_summary(ticket)
      )
    end

    json
  end

  def event_change_refund_contact_support?(ticket)
    return false unless ticket.issued? && ticket.held_by?(@current_user) &&
      ticket.transferred_away_from?(ticket.order) && ticket.order.total_cents.positive? &&
      (ticket.order_item ? ticket.refundable_cents.positive? : ticket.ticket_type.price_cents.positive?)

    change = ticket.event.event_changes.buyer_visible.order(:occurred_at, :id).last
    eligibility = EventChangeRefundEligibility.call(order: ticket.order, change: change)
    eligibility.eligible? || eligibility.reason == "no_tickets"
  end

  def parent_display_exposes_children?(ticket)
    !ticket.cancelled? &&
      !ticket.refund_pending? &&
      !ticket.inventory_retained? &&
      !ticket.transferred? &&
      !ticket.transferred_away_from?(ticket.order) &&
      !ticket.order.ticket_access_blocked?
  end

  def admission_access?(ticket)
    return true if @current_user&.admin?
    return ticket.held_by?(@current_user) if ticket.holder_user_id.present?
    return true if ticket.order.user_id.present? && ticket.order.user_id == @current_user&.id

    token = request.headers["X-Guest-Order-Token"].presence
    token.present? && GuestOrderAccess.find(token)&.id == ticket.order_id
  end
end
