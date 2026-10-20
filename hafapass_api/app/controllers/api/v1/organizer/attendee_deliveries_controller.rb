# frozen_string_literal: true

# Organizer-side "Resend ticket" for one attendee row. Reuses the buyer-facing
# FulfillmentResender so the same cooldown, unconfirmed-delivery guard and
# durable MessageDelivery apply; the email goes to the order's buyer address.
class Api::V1::Organizer::AttendeeDeliveriesController < Api::V1::Organizer::BaseController
  def create
    event = find_organization_event(params[:event_id])
    return unless event && authorize_organization!(:manage_attendees, event: event)

    ticket = event.tickets.includes(:order).find_by(id: params[:ticket_id])
    return render json: { error: "Attendee not found" }, status: :not_found unless ticket

    order = ticket.order
    unless ticket.issued? || ticket.checked_in?
      return render json: { error: "Only active tickets can be resent" }, status: :unprocessable_entity
    end
    if ticket.transferred_away_from?(order)
      return render json: { error: "This ticket was transferred. Its new holder can open it from My Tickets." },
        status: :unprocessable_entity
    end

    delivery = FulfillmentResender.call(order: order, requested_by: current_user)
    AuditLogger.record!(action: "order.fulfillment_resent", auditable: order, actor: current_user,
      organization: event.organization, metadata: { message_delivery_id: delivery.id, ticket_id: ticket.id },
      request: request)
    render json: { message: "Ticket email queued", recipient: order.buyer_email }, status: :accepted
  rescue FulfillmentResender::Unconfirmed => e
    render json: { error: e.message, reconciliation_required: true }, status: :conflict
  rescue FulfillmentResender::Cooldown => e
    render json: { error: e.message }, status: :too_many_requests
  rescue FulfillmentResender::NotAvailable => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
end
