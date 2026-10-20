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
    # What one email attaches, decided once so the payload and the email copy
    # agree: the attachments, how many tickets could have one, and how many
    # tickets the email covers.
    Plan = Struct.new(:attachments, :attachable_count, :ticket_count, keyword_init: true) do
      def any?
        attachments.any?
      end

      def capped?
        attachable_count > attachments.length
      end

      def complete?
        attachments.length == ticket_count
      end
    end

    def plan(tickets)
      tickets = Array(tickets)
      base = api_base
      attachable = base ? tickets.select { |ticket| attachable?(ticket) } : []
      attachments = attachable.first(MAX_ATTACHMENTS).map do |ticket|
        { filename: "hafapass-ticket-#{ticket.id}.pdf", path: "#{base}#{ROUTE}/#{token(ticket)}" }
      end
      Plan.new(attachments: attachments, attachable_count: attachable.length, ticket_count: tickets.length)
    end

    def for(tickets)
      plan(tickets).attachments
    end

    # Exactly the tickets that admit right now (Ticket#admission_allowed?), so
    # the two never drift: blocked, refunded, disputed, cancelled, transferred
    # and unpublished-event tickets never get a PDF.
    def attachable?(ticket)
      ticket.admission_allowed?
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
