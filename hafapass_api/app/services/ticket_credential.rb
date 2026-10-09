# frozen_string_literal: true

class TicketCredential
  DISPLAY_PURPOSE = "ticket_display"
  SCAN_PURPOSE = "ticket_scan"

  class << self
    def display(ticket)
      issue(ticket, purpose: DISPLAY_PURPOSE, version: ticket.display_credential_version)
    end

    def scan(ticket)
      issue(ticket, purpose: SCAN_PURPOSE, version: ticket.scan_credential_version)
    end

    def find_display(token)
      find(token, purpose: DISPLAY_PURPOSE, version_attribute: :display_credential_version)
    end

    def find_scan(token)
      find(token, purpose: SCAN_PURPOSE, version_attribute: :scan_credential_version)
    end

    def valid_scan_for?(ticket, token)
      payload = SignedCredential.verify(namespace: SCAN_PURPOSE, token: token)
      return false if payload.blank?

      id = payload["ticket_id"] || payload[:ticket_id]
      version = payload["version"] || payload[:version]
      id.to_s == ticket.id.to_s && ActiveSupport::SecurityUtils.secure_compare(
        ticket.scan_credential_version.to_s, version.to_s
      )
    end

    private

    def issue(ticket, purpose:, version:)
      SignedCredential.issue(
        namespace: purpose,
        payload: { ticket_id: ticket.id, version: version }
      )
    end

    def find(token, purpose:, version_attribute:)
      payload = SignedCredential.verify(namespace: purpose, token: token)
      return if payload.blank?

      ticket = Ticket.find_by(id: payload["ticket_id"] || payload[:ticket_id])
      version = payload["version"] || payload[:version]
      return unless ticket && ActiveSupport::SecurityUtils.secure_compare(ticket.public_send(version_attribute).to_s, version.to_s)

      ticket
    end
  end
end
