# frozen_string_literal: true

require "digest"
require "json"

module Wallet
  # The Google Wallet EventTicketClass/EventTicketObject for one recorded pass.
  # The save link and the REST update share it, so a saved object and its later
  # updates cannot drift.
  class GoogleTicketObject
    def initialize(wallet_pass, at: Time.current)
      @wallet_pass = wallet_pass
      @ticket = wallet_pass.ticket
      @state = wallet_pass.state
      @at = at
    end

    def event_class
      event = ticket.event
      {
        id: class_id,
        issuerName: "HåfaPass",
        reviewStatus: ENV.fetch("GOOGLE_WALLET_CLASS_REVIEW_STATUS", "UNDER_REVIEW"),
        eventName: localized(event.title),
        venue: { name: localized(event.venue_name.to_s), address: localized(event.venue_address.to_s) },
        dateTime: { start: event.starts_at&.iso8601, end: (event.ends_at || event.starts_at)&.iso8601 }
      }
    end

    # Only a current, admissible credential carries a barcode. Updates replace
    # the whole object, so omitting it removes a dead QR from the saved pass.
    def ticket_object
      {
        id: wallet_pass.serial_number,
        classId: class_id,
        state: state.google_state(at: at),
        # A replaced object (e.g. the sender's after a transfer) never shows the
        # current holder's name, seat or ticket type.
        ticketHolderName: state.current_credential? ? ticket.attendee_name.to_s : nil,
        ticketNumber: ticket.id.to_s,
        ticketType: state.current_credential? ? localized([ticket.ticket_type.name, ticket.seat_label].compact.join(" · ")) : nil,
        textModulesData: [{ id: "status", header: "Status", body: state.status_label }],
        barcode: state.barcode? ? { type: "QR_CODE", value: ticket.scan_credential, alternateText: "HåfaPass #{ticket.id}" } : nil
      }.compact
    end

    def content_digest
      Digest::SHA256.hexdigest(JSON.generate(ticket_object))
    end

    private

    attr_reader :wallet_pass, :ticket, :state, :at

    def class_id
      GoogleSaveLink.class_id_for(ticket.event)
    end

    def localized(value)
      { defaultValue: { language: "en-US", value: value } }
    end
  end
end
