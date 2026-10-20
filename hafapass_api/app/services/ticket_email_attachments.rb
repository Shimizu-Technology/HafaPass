# frozen_string_literal: true

# Ticket PDFs attached to confirmation and ticket emails, so a buyer can open
# their ticket offline at the door. The durable email payload stores only a
# short-lived signed URL; the email provider fetches the PDF when it sends, so
# retries replay identical bytes and stored payloads stay small.
class TicketEmailAttachments
  NAMESPACE = "ticket_email_attachment"
  ROUTE = "/api/v1/ticket_email_attachments"
  MAX_ATTACHMENTS = 10
  # Longer than the provider replay window, so a retried send still resolves.
  TTL = 3.days

  class << self
    # True when at least one ticket would get a PDF, for the email copy.
    def any?(tickets)
      api_base.present? && Array(tickets).any? { |ticket| attachable?(ticket) }
    end

    def for(tickets)
      base = api_base
      return [] unless base

      Array(tickets).select { |ticket| attachable?(ticket) }.first(MAX_ATTACHMENTS).map do |ticket|
        { filename: "hafapass-ticket-#{ticket.id}.pdf", path: "#{base}#{ROUTE}/#{token(ticket)}" }
      end
    end

    # Only a ticket that admits right now gets a PDF; blocked, refunded,
    # disputed, cancelled or transferred tickets never do.
    def attachable?(ticket)
      ticket.issued? && ticket.order.ticket_fulfilled? && !ticket.order.ticket_access_blocked? &&
        !ticket.refund_pending? && !ticket.inventory_retained?
    end

    # Returns [ticket, still_valid] for a signed URL, or nil when unknown/expired.
    def resolve(token)
      payload = SignedCredential.verify(namespace: NAMESPACE, token: token)
      return if payload.blank?

      ticket = Ticket.includes(:order, :event, :ticket_type).find_by(id: payload["ticket_id"])
      return unless ticket

      [ticket, binding_for(ticket) == payload.slice("version", "scan_version", "holder_user_id") && attachable?(ticket)]
    end

    private

    # The PDF draws the live scan credential, so the link is bound to every
    # value that changes who may enter: a QR refresh, a transfer or a new
    # holder each turn an old link into the "no longer valid" notice.
    def binding_for(ticket)
      { "version" => ticket.display_credential_version, "scan_version" => ticket.scan_credential_version,
        "holder_user_id" => ticket.holder_user_id }
    end

    def token(ticket)
      SignedCredential.issue(namespace: NAMESPACE, payload: { ticket_id: ticket.id, **binding_for(ticket).symbolize_keys },
        expires_at: TTL.from_now)
    end

    # The provider must reach the URL, so attachments need the public HTTPS API.
    def api_base
      PublicSiteUrl.api
    end
  end
end
