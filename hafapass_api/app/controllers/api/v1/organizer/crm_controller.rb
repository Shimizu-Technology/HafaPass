# frozen_string_literal: true

require "csv"

class Api::V1::Organizer::CrmController < Api::V1::Organizer::EventResourcesController
  include SpreadsheetExport

  def segments
    scope = active_tickets
    render json: {
      segments: {
        all_attendees: scope.distinct.count(:holder_email),
        checked_in: scope.where(status: :checked_in).distinct.count(:holder_email),
        not_checked_in: scope.where(status: :issued).distinct.count(:holder_email),
        ticket_types: event.ticket_types.order(:id).map do |type|
          { id: type.id, name: type.name, recipients: scope.where(ticket_type: type).distinct.count(:holder_email) }
        end
      }
    }
  end

  def export
    if AuditLog.where(actor_user: current_user, action: "sales.exported", occurred_at: 1.hour.ago..).count >= 10
      return render json: { error: "Export limit reached. Try again later." }, status: :too_many_requests
    end

    query = OrganizerSalesQuery.new(event: event, params: params.to_unsafe_h.merge("view" => "tickets"),
      attendee_access: true)
    rows = query.each_batch.lazy.select { |ticket| !ticket.cancelled? && ticket.holder_email.present? }
    count = query.relation.where.not(status: Ticket.statuses[:cancelled]).where.not(holder_email: [nil, ""]).count
    AuditLogger.record!(action: "sales.exported", auditable: event, actor: current_user,
      organization: current_organization, metadata: { filters: query.filters, columns: %w[name email ticket_type ticket_status checked_in_at order_reference purchased_at], row_count: count }, request: request)
    stream_csv(filename: "#{event.slug}-attendees.csv",
      header: %w[name email ticket_type ticket_status checked_in_at order_reference purchased_at],
      bom: true,
      rows: rows.map { |ticket| [ticket.attendee_name, ticket.holder_email, ticket.ticket_type.name, ticket.status,
        ticket.checked_in_at, ticket.order.reference, ticket.order.completed_at] })
  rescue OrganizerSalesQuery::InvalidFilter => error
    render json: { error: error.message }, status: :unprocessable_entity
  end

  private

  def resource_permission
    :view_attendees
  end

  def active_tickets
    event.tickets.where.not(status: :cancelled).where.not(holder_email: nil)
  end
end
