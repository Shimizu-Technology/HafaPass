class Api::V1::CheckInsController < ApplicationController
  def create
    credential = params[:credential] || params[:qr_code]
    resolved_ticket = TicketCredential.find_scan(credential)
    ticket = Ticket.includes(:order, :ticket_type, event: [:organizer_profile, :organization]).find_by(id: resolved_ticket&.id)

    unless ticket
      render json: { error: "Ticket not found" }, status: :not_found
      return
    end

    unless authorized_to_check_in?(ticket)
      render json: { error: "Not authorized to check in this ticket" }, status: :forbidden
      return
    end

    unless ticket.order.ticket_fulfilled?
      render json: { error: "Ticket order is not fulfilled" }, status: :unprocessable_entity
      return
    end

    if ticket.order.ticket_access_blocked?
      render json: { error: "Ticket access is suspended while a payment dispute is reviewed", ticket: ticket_json(ticket) },
        status: :unprocessable_entity
      return
    end

    unless ticket.event.published?
      render json: { error: "Event is #{ticket.event.status}; check-in is unavailable", ticket: ticket_json(ticket) },
        status: :unprocessable_entity
      return
    end

    if ticket.checked_in?
      render json: {
        error: "Ticket already checked in",
        checked_in_at: ticket.checked_in_at,
        ticket: ticket_json(ticket)
      }, status: :unprocessable_entity
      return
    end

    if ticket.cancelled?
      render json: {
        error: "Ticket is cancelled",
        ticket: ticket_json(ticket)
      }, status: :unprocessable_entity
      return
    end

    ticket.check_in!
    AuditLogger.record!(
      action: "ticket.checked_in",
      auditable: ticket,
      actor: current_user,
      organization: ticket.event.organization,
      metadata: { event_id: ticket.event_id },
      request: request
    )
    render json: { message: "Check-in successful", ticket: ticket_json(ticket) }, status: :ok
  end

  private

  def authorized_to_check_in?(ticket)
    OrganizationAuthorization.allowed?(
      user: current_user,
      organization: ticket.event.organization,
      permission: :scan,
      event: ticket.event
    )
  end

  def ticket_json(ticket)
    {
      id: ticket.id,
      status: ticket.status,
      attendee_name: ticket.attendee_name,
      checked_in_at: ticket.checked_in_at,
      event: {
        id: ticket.event.id,
        title: ticket.event.title,
        slug: ticket.event.slug,
        status: ticket.event.status,
        venue_name: ticket.event.venue_name,
        starts_at: ticket.event.starts_at,
        timezone: ticket.event.timezone
      },
      ticket_type: {
        id: ticket.ticket_type.id,
        name: ticket.ticket_type.name,
        price_cents: ticket.ticket_type.price_cents
      }
    }
  end
end
