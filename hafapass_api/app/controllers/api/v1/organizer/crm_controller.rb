# frozen_string_literal: true

require "csv"

class Api::V1::Organizer::CrmController < Api::V1::Organizer::EventResourcesController
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
    csv = CSV.generate(headers: true) do |output|
      output << %w[name email ticket_type ticket_status checked_in_at order_reference purchased_at]
      active_tickets.includes(:ticket_type, :order).order(:id).each do |ticket|
        output << [ticket.attendee_name, ticket.holder_email, ticket.ticket_type.name, ticket.status,
          ticket.checked_in_at, ticket.order.reference, ticket.order.completed_at]
      end
    end
    send_data csv, type: "text/csv", filename: "#{event.slug}-attendees.csv", disposition: "attachment"
  end

  private

  def resource_permission
    :view_attendees
  end

  def active_tickets
    event.tickets.where.not(status: :cancelled).where.not(holder_email: nil)
  end
end
