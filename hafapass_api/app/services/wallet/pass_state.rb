# frozen_string_literal: true

module Wallet
  # What a saved wallet pass may show for one issued credential version. A pass
  # carries a barcode only while that exact credential admits; anything that
  # permanently replaces or ends the ticket voids it.
  class PassState
    attr_reader :ticket, :scan_credential_version

    def initialize(ticket, scan_credential_version: ticket.scan_credential_version)
      @ticket = ticket
      @scan_credential_version = scan_credential_version
    end

    def current_credential?
      ticket.scan_credential_version == scan_credential_version
    end

    def barcode?
      current_credential? && ticket.admission_allowed?
    end

    def voided?
      !current_credential? || ticket.cancelled? || ticket.transferred? || ticket.inventory_retained? ||
        ticket.order.refunded? || ticket.order.cancelled? || ticket.event.cancelled? || ticket.event.archived?
    end

    def event_ended?(at: Time.current)
      ending = ticket.event.ends_at || ticket.event.starts_at
      ending.present? && ending < at
    end

    def status_label
      return "Replaced — open HåfaPass for the current ticket" unless current_credential?
      return "Cancelled" if ticket.cancelled? || ticket.order.cancelled?
      return "Transferred" if ticket.transferred?
      return "Refunded" if ticket.order.refunded? || ticket.inventory_retained?
      return "Event cancelled" if ticket.event.cancelled?
      return "No longer available" if ticket.event.archived?
      return "Checked in" if ticket.checked_in?
      return "Paused — payment dispute under review" if ticket.order.ticket_access_blocked?
      return "Paused — refund pending" if ticket.refund_pending?
      return "Event postponed" if ticket.event.postponed?
      return "Valid" if barcode?

      "Not valid for entry"
    end

    def google_state(at: Time.current)
      return "INACTIVE" if voided?
      return "EXPIRED" if event_ended?(at: at)
      return "COMPLETED" if ticket.checked_in?

      barcode? ? "ACTIVE" : "INACTIVE"
    end
  end
end
