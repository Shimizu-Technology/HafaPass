# frozen_string_literal: true

require "base64"
require "digest/sha1"
require "json"
require "openssl"
require "securerandom"
require "zip"

module Wallet
  class ApplePassGenerator
    class ConfigurationError < StandardError; end

    WEB_SERVICE_PATH = "/api/v1/wallet/apple"

    def self.configured?
      %w[APPLE_PASS_TYPE_IDENTIFIER APPLE_TEAM_IDENTIFIER APPLE_PASS_CERTIFICATE_BASE64
        APPLE_WWDR_CERTIFICATE_BASE64 APPLE_PASS_ICON_PATH].all? { |key| ENV[key].present? }
    end

    def self.enabled?
      configured? && PlatformCapabilities.enabled?("apple_wallet")
    end

    def self.pass_type_identifier
      ENV["APPLE_PASS_TYPE_IDENTIFIER"].to_s
    end

    # Apple appends /v1/devices/... and /v1/passes/... to this base. Passes
    # only advertise it on an HTTPS API origin, which production requires.
    def self.web_service_url
      base = PublicSiteUrl.api
      "#{base}#{WEB_SERVICE_PATH}" if base
    end

    def self.serial_for(ticket)
      "ticket-#{ticket.id}-v#{ticket.scan_credential_version}"
    end

    # Issues a pass for the ticket's current credential and records it so later
    # state changes can update or void it.
    def self.call(ticket)
      raise ConfigurationError, "Apple Wallet is not configured" unless configured?
      raise ConfigurationError, "Apple Wallet is disabled pending provider approval" unless enabled?

      wallet_pass = WalletPass.record!(provider: "apple", serial_number: serial_for(ticket), ticket: ticket)
      raise ConfigurationError, "Apple Wallet pass belongs to another ticket" unless wallet_pass.ticket_id == ticket.id

      token = SecureRandom.urlsafe_base64(32)
      wallet_pass.add_authentication_token!(token)
      generator = new(wallet_pass, authentication_token: token)
      wallet_pass.record_content!(generator.content_digest)
      generator.call
    end

    # The latest version of an already issued pass, for the PassKit web service.
    def self.latest(wallet_pass, authentication_token:)
      new(wallet_pass, authentication_token: authentication_token).call
    end

    def self.content_digest(wallet_pass)
      new(wallet_pass, authentication_token: nil).content_digest
    end

    def initialize(wallet_pass, authentication_token:)
      @wallet_pass = wallet_pass
      @ticket = wallet_pass.ticket
      @state = wallet_pass.state
      @authentication_token = authentication_token
    end

    def call
      raise ConfigurationError, "Apple Wallet is not configured" unless self.class.configured?
      raise ConfigurationError, "Apple Wallet is disabled pending provider approval" unless self.class.enabled?

      files = { "pass.json" => JSON.generate(pass_payload) }.merge(icon_files)
      manifest = JSON.generate(files.transform_values { |contents| Digest::SHA1.hexdigest(contents) })
      files["manifest.json"] = manifest
      files["signature"] = signature(manifest)

      Zip::OutputStream.write_buffer do |archive|
        files.each do |name, contents|
          archive.put_next_entry(name)
          archive.write(contents)
        end
      end.string
    rescue OpenSSL::OpenSSLError, ArgumentError, Errno::ENOENT => e
      raise ConfigurationError, "Apple Wallet signing failed: #{e.message}"
    end

    # Everything a holder can see, excluding the per-copy token, so a changed
    # digest means the saved pass needs an update.
    def content_digest
      Digest::SHA256.hexdigest(JSON.generate(visible_payload))
    end

    private

    attr_reader :ticket, :state, :wallet_pass, :authentication_token

    # APPLE_PASS_ICON_PATH may be relative to the app root (the bundled
    # app/assets/wallet/icon.png). Retina variants are used when they sit next
    # to it as icon@2x.png and icon@3x.png; otherwise the base icon is reused.
    def icon_files
      base = Rails.root.join(ENV.fetch("APPLE_PASS_ICON_PATH"))
      icon = File.binread(base)
      variant = lambda do |scale|
        path = base.sub_ext("@#{scale}x#{base.extname}")
        path.file? ? File.binread(path) : icon
      end
      { "icon.png" => icon, "icon@2x.png" => variant.call(2), "icon@3x.png" => variant.call(3) }
    end

    def pass_payload
      payload = visible_payload
      service_url = self.class.web_service_url
      if service_url && authentication_token.present?
        payload = payload.merge(webServiceURL: service_url, authenticationToken: authentication_token)
      end
      payload
    end

    def visible_payload
      event = ticket.event
      {
        formatVersion: 1,
        passTypeIdentifier: ENV.fetch("APPLE_PASS_TYPE_IDENTIFIER"),
        serialNumber: wallet_pass.serial_number,
        teamIdentifier: ENV.fetch("APPLE_TEAM_IDENTIFIER"),
        organizationName: "HåfaPass",
        description: "Ticket for #{event.title}",
        logoText: "HåfaPass",
        foregroundColor: "rgb(255, 255, 255)",
        backgroundColor: "rgb(14, 124, 123)",
        relevantDate: event.starts_at&.iso8601,
        expirationDate: (event.ends_at || event.starts_at)&.iso8601,
        voided: state.voided?,
        eventTicket: {
          headerFields: [{ key: "status", label: "STATUS", value: state.status_label, changeMessage: "Ticket status: %@" }],
          primaryFields: [{ key: "event", label: "EVENT", value: event.title }],
          secondaryFields: [
            { key: "date", label: "DATE", value: event.starts_at&.iso8601, dateStyle: "PKDateStyleMedium",
              timeStyle: "PKDateStyleShort", changeMessage: "Event time changed to %@" },
            { key: "venue", label: "VENUE", value: event.venue_name.to_s }
          ],
          # A replaced copy (e.g. the sender's after a transfer) never shows
          # the current holder's name, seat or ticket type.
          auxiliaryFields: (holder_details? ? [
            { key: "ticket", label: "TICKET", value: ticket.ticket_type.name },
            (ticket.seat_label && { key: "seat", label: "SEAT", value: ticket.seat_label })
          ].compact : []),
          backFields: [
            ({ key: "holder", label: "TICKET HOLDER", value: ticket.attendee_name.to_s } if holder_details?),
            { key: "address", label: "VENUE ADDRESS", value: event.venue_address.to_s }
          ].compact
        },
        barcode: barcode,
        barcodes: barcode && [barcode]
      }.compact
    end

    def holder_details?
      state.current_credential?
    end

    # A pass without a current, admissible credential carries no barcode.
    def barcode
      return unless state.barcode?

      { format: "PKBarcodeFormatQR", message: ticket.scan_credential,
        messageEncoding: "iso-8859-1", altText: "HåfaPass #{ticket.id}" }
    end

    def signature(manifest)
      credentials = ApplePassCertificate.load
      wwdr = OpenSSL::X509::Certificate.new(Base64.strict_decode64(ENV.fetch("APPLE_WWDR_CERTIFICATE_BASE64")))
      OpenSSL::PKCS7.sign(credentials.certificate, credentials.key, manifest, [wwdr],
        OpenSSL::PKCS7::BINARY | OpenSSL::PKCS7::DETACHED).to_der
    end
  end
end
