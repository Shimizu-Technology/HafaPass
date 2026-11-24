# frozen_string_literal: true

module Commerce
  class BoxOfficeReceipt
    ACTIVE_EMAIL_STATUSES = %w[queued sent delivered delayed].freeze

    def initialize(order)
      @order = order
    end

    def as_json
      {
        id: order.id,
        reference: order.reference,
        status: order.status,
        total_cents: order.total_cents,
        event_title: order.event.title,
        email: email,
        email_available: fulfilled?,
        email_status: email_status,
        admissions: admissions
      }
    end

    def fulfilled?
      order.ticket_fulfilled? && !order.ticket_access_blocked? && !order.full_refund_pending?
    end

    def email_status
      return unless email

      order.message_deliveries.ticket_email.where(recipient: email.downcase).order(id: :desc).pick(:status)
    end

    def email
      address = order.buyer_email
      address if address.present? && !address.downcase.end_with?("@boxoffice.local")
    end

    private

    attr_reader :order

    def admissions
      return [] unless fulfilled?

      order.tickets.scannable.includes(:event, :ticket_type, :inventory_retention, :pending_refund_tickets,
        parent_ticket: [:inventory_retention, :pending_refund_tickets],
        event_seat: { venue_seat: { seating_row: :seating_section } })
        .order(:id).filter_map do |ticket|
        next if ticket.transferred_away_from?(order) || ticket.parent_ticket&.transferred_away_from?(order)
        next unless ticket.admission_allowed?

        {
          id: ticket.id,
          scan_credential: ticket.scan_credential,
          tier: ticket.ticket_type.name,
          attendee_name: ticket.attendee_name == "Walk-in" ? nil : ticket.attendee_name,
          seat: ticket.seat_label,
          pass_night: ticket.pass_child?,
          event: ticket.event.as_json(only: [:title, :starts_at, :timezone, :venue_name, :venue_address])
        }
      end
    end
  end
end
