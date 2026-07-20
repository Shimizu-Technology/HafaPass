# frozen_string_literal: true

require "digest"

class Api::V1::Support::SearchController < Api::V1::Support::BaseController
  LIMIT = 20

  def index
    query = params[:q].to_s.strip
    return render json: { error: "Enter at least 3 characters" }, status: :unprocessable_entity if query.length < 3

    pattern = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
    orders = Order.includes(:event, :tickets, :message_deliveries)
      .where("reference ILIKE :pattern OR buyer_email ILIKE :pattern OR buyer_name ILIKE :pattern", pattern: pattern)
      .order(created_at: :desc).limit(LIMIT)
    tickets = Ticket.includes(:event, :ticket_type, :order)
      .where("attendee_email ILIKE :pattern OR attendee_name ILIKE :pattern OR qr_code = :exact", pattern: pattern, exact: query)
      .order(created_at: :desc).limit(LIMIT)
    events = Event.includes(:organization).where("title ILIKE :pattern OR slug ILIKE :pattern", pattern: pattern)
      .order(starts_at: :desc).limit(LIMIT)

    AuditLogger.record!(action: "support.lookup", auditable: current_user, actor: current_user,
      metadata: { query_digest: Digest::SHA256.hexdigest(query.downcase), result_counts: {
        orders: orders.length, tickets: tickets.length, events: events.length
      } }, request: request)

    render json: {
      orders: orders.map { |order| order_json(order) },
      tickets: tickets.map { |ticket| ticket_json(ticket) },
      events: events.map { |event| event_json(event) }
    }
  end

  private

  def order_json(order)
    {
      id: order.id,
      reference: order.reference,
      buyer_name: order.buyer_name,
      buyer_email: order.buyer_email,
      status: order.status,
      event_id: order.event_id,
      event_title: order.event.title,
      ticket_count: order.tickets.size,
      delivery_statuses: order.message_deliveries.group_by(&:status).transform_values(&:size),
      created_at: order.created_at
    }
  end

  def ticket_json(ticket)
    {
      id: ticket.id,
      order_id: ticket.order_id,
      order_reference: ticket.order.reference,
      event_id: ticket.event_id,
      event_title: ticket.event.title,
      ticket_type: ticket.ticket_type.name,
      attendee_name: ticket.attendee_name,
      attendee_email: ticket.attendee_email,
      status: ticket.status
    }
  end

  def event_json(event)
    {
      id: event.id,
      title: event.title,
      slug: event.slug,
      status: event.status,
      starts_at: event.starts_at,
      organization_name: event.organization.name
    }
  end
end
