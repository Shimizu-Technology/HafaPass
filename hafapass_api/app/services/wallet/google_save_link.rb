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

    def self.enabled?
      configured? && PlatformCapabilities.enabled?("google_wallet")
    end

    def self.object_id_for(ticket)
      "#{issuer_id}.hafapass_ticket_#{ticket.id}_v#{ticket.scan_credential_version}"
    end

    def self.class_id_for(event)
      "#{issuer_id}.hafapass_event_#{event.id}"
    end

    def self.issuer_id
      ENV.fetch("GOOGLE_WALLET_ISSUER_ID")
    end

    def self.private_key
      OpenSSL::PKey::RSA.new(ENV.fetch("GOOGLE_WALLET_PRIVATE_KEY").gsub("\\n", "\n"))
    end

    def self.call(ticket)
      new(ticket).call
    end

    def initialize(ticket)
      @ticket = ticket
    end

    def call
      raise ConfigurationError, "Google Wallet is not configured" unless self.class.configured?
      raise ConfigurationError, "Google Wallet is disabled pending provider approval" unless self.class.enabled?

      wallet_pass = record_wallet_pass!
      object = GoogleTicketObject.new(wallet_pass)
      wallet_pass.record_content!(object.content_digest)
      token = JWT.encode(claims(object), self.class.private_key, "RS256")
      "https://pay.google.com/gp/v/save/#{token}"
    rescue OpenSSL::PKey::PKeyError, JWT::EncodeError => e
      raise ConfigurationError, "Google Wallet signing failed: #{e.message}"
    end

    private

    attr_reader :ticket

    # Remembering the object lets later state changes update or deactivate it.
    def record_wallet_pass!
      wallet_pass = WalletPass.record!(provider: "google", serial_number: self.class.object_id_for(ticket), ticket: ticket)
      raise ConfigurationError, "Google Wallet object belongs to another ticket" unless wallet_pass.ticket_id == ticket.id

      wallet_pass
    end

    def claims(object)
      {
        iss: ENV.fetch("GOOGLE_WALLET_SERVICE_ACCOUNT_EMAIL"),
        aud: "google",
        typ: "savetowallet",
        iat: Time.current.to_i,
        origins: [ENV.fetch("FRONTEND_URL", "http://localhost:5173")],
        payload: {
          eventTicketClasses: [object.event_class],
          eventTicketObjects: [object.ticket_object]
        }
      }
    end
  end
end
