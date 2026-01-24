class Api::V1::Me::OrdersController < ApplicationController
  def index
    orders = current_user.orders
      .includes(event: [], tickets: :ticket_type)
      .order(created_at: :desc)

    render json: orders.map { |order| order_json(order) }
  end

  def show
    order = current_user.orders
      .includes(event: [], tickets: :ticket_type)
      .find_by(id: params[:id])

    unless order
      render json: { error: "Order not found" }, status: :not_found
      return
    end

    render json: order_json(order)
  end

  private

  def order_json(order)
    {
      id: order.id,
      event_id: order.event_id,
      status: order.status,
      subtotal_cents: order.subtotal_cents,
      service_fee_cents: order.service_fee_cents,
      total_cents: order.total_cents,
      buyer_email: order.buyer_email,
      buyer_name: order.buyer_name,
      buyer_phone: order.buyer_phone,
      completed_at: order.completed_at,
      created_at: order.created_at,
      event: event_json(order.event),
      tickets: order.tickets.map { |ticket| ticket_json(ticket) }
    }
  end

  def event_json(event)
    {
      id: event.id,
      title: event.title,
      slug: event.slug,
      venue_name: event.venue_name,
      starts_at: event.starts_at,
      ends_at: event.ends_at,
      cover_image_url: event.cover_image_url
    }
  end

  def ticket_json(ticket)
    {
      id: ticket.id,
      qr_code: ticket.qr_code,
      status: ticket.status,
      attendee_name: ticket.attendee_name,
      attendee_email: ticket.attendee_email,
      checked_in_at: ticket.checked_in_at,
      ticket_type: {
        id: ticket.ticket_type.id,
        name: ticket.ticket_type.name,
        price_cents: ticket.ticket_type.price_cents
      }
    }
  end
end
