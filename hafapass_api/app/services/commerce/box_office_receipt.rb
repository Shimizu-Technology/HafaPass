# frozen_string_literal: true

module Commerce
  class BoxOfficeReceipt
    ACTIVE_EMAIL_STATUSES = %w[queued sent delivered delayed].freeze
    # Reserved placeholder domains can never receive mail, so they never count
    # as a buyer address (walk-in placeholder, guest list, privacy deletion).
    PLACEHOLDER_DOMAINS = %w[@boxoffice.local @hafapass.invalid @privacy.invalid].freeze
    # Deliveries suppressed at creation (privacy deletion) store this recipient
    # instead of the buyer address, so a reload must look for it too.
    SUPPRESSED_RECIPIENT = "deleted@privacy.invalid"

    def self.deliverable_address?(address)
      normalized = address.to_s.strip.downcase
      normalized.present? && PLACEHOLDER_DOMAINS.none? { |domain| normalized.end_with?(domain) }
    end

    def initialize(order)
      @order = order
      # One query per association instead of one per ticket and per check.
      ActiveRecord::Associations::Preloader.new(records: [order], associations: [:disputes, :refunds, :payments]).call
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

      order.message_deliveries.ticket_email.where(recipient: [email.downcase, SUPPRESSED_RECIPIENT])
        .order(id: :desc).pick(:status)
    end

    def email
      address = order.buyer_email.to_s.strip
      address if self.class.deliverable_address?(address)
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
