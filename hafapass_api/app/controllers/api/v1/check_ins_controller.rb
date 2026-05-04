class Api::V1::CheckInsController < ApplicationController
  def create
    ticket = Ticket.includes(:order, :ticket_type, event: :organizer_profile).find_by(qr_code: params[:qr_code])

    unless ticket
      render json: { error: "Ticket not found" }, status: :not_found
      return
    end

    unless authorized_to_check_in?(ticket)
      render json: { error: "Not authorized to check in this ticket" }, status: :forbidden
      return
    end

    unless ticket.order.completed?
      render json: { error: "Ticket order is not completed" }, status: :unprocessable_entity
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
    render json: { message: "Check-in successful", ticket: ticket_json(ticket) }, status: :ok
  end

  private

  def authorized_to_check_in?(ticket)
    return true if current_user.admin?

    current_user.organizer_profile&.id == ticket.event.organizer_profile_id
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
        starts_at: ticket.event.starts_at
      },
      ticket_type: {
        id: ticket.ticket_type.id,
        name: ticket.ticket_type.name,
        price_cents: ticket.ticket_type.price_cents
      }
    }
  end
end
