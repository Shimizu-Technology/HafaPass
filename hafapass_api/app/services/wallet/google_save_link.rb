# frozen_string_literal: true

require "jwt"

module Wallet
  class GoogleSaveLink
    class ConfigurationError < StandardError; end

    def self.configured?
      %w[GOOGLE_WALLET_ISSUER_ID GOOGLE_WALLET_SERVICE_ACCOUNT_EMAIL GOOGLE_WALLET_PRIVATE_KEY].all? do |key|
        ENV[key].present?
      end
    end

    def self.call(ticket)
      new(ticket).call
    end

    def initialize(ticket)
      @ticket = ticket
    end

    def call
      raise ConfigurationError, "Google Wallet is not configured" unless self.class.configured?

      token = JWT.encode(claims, OpenSSL::PKey::RSA.new(normalized_private_key), "RS256")
      "https://pay.google.com/gp/v/save/#{token}"
    rescue OpenSSL::PKey::PKeyError, JWT::EncodeError => e
      raise ConfigurationError, "Google Wallet signing failed: #{e.message}"
    end

    private

    attr_reader :ticket

    def claims
      {
        iss: ENV.fetch("GOOGLE_WALLET_SERVICE_ACCOUNT_EMAIL"),
        aud: "google",
        typ: "savetowallet",
        iat: Time.current.to_i,
        origins: [ENV.fetch("FRONTEND_URL", "http://localhost:5173")],
        payload: {
          eventTicketClasses: [event_class],
          eventTicketObjects: [ticket_object]
        }
      }
    end

    def event_class
      event = ticket.event
      {
        id: class_id,
        issuerName: "HafaPass",
        reviewStatus: "UNDER_REVIEW",
        eventName: localized(event.title),
        venue: { name: localized(event.venue_name.to_s), address: localized(event.venue_address.to_s) },
        dateTime: { start: event.starts_at&.iso8601, end: (event.ends_at || event.starts_at)&.iso8601 }
      }
    end

    def ticket_object
      {
        id: pass_object_id,
        classId: class_id,
        state: ticket.admission_allowed? ? "ACTIVE" : "INACTIVE",
        ticketHolderName: ticket.attendee_name.to_s,
        ticketNumber: ticket.id.to_s,
        ticketType: localized(ticket.ticket_type.name),
        barcode: { type: "QR_CODE", value: ticket.scan_credential, alternateText: "HafaPass #{ticket.id}" }
      }
    end

    def localized(value)
      { defaultValue: { language: "en-US", value: value } }
    end

    def class_id
      "#{issuer_id}.hafapass_event_#{ticket.event_id}"
    end

    def pass_object_id
      "#{issuer_id}.hafapass_ticket_#{ticket.id}_v#{ticket.scan_credential_version}"
    end

    def issuer_id
      ENV.fetch("GOOGLE_WALLET_ISSUER_ID")
    end

    def normalized_private_key
      ENV.fetch("GOOGLE_WALLET_PRIVATE_KEY").gsub("\\n", "\n")
    end
  end
end
