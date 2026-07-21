# frozen_string_literal: true

require "base64"
require "digest/sha1"
require "json"
require "openssl"
require "zip"

module Wallet
  class ApplePassGenerator
    class ConfigurationError < StandardError; end

    def self.configured?
      %w[APPLE_PASS_TYPE_IDENTIFIER APPLE_TEAM_IDENTIFIER APPLE_PASS_CERTIFICATE_BASE64
        APPLE_WWDR_CERTIFICATE_BASE64 APPLE_PASS_ICON_PATH].all? { |key| ENV[key].present? }
    end

    def self.call(ticket)
      new(ticket).call
    end

    def initialize(ticket)
      @ticket = ticket
    end

    def call
      raise ConfigurationError, "Apple Wallet is not configured" unless self.class.configured?

      files = {
        "pass.json" => JSON.generate(pass_payload),
        "icon.png" => File.binread(ENV.fetch("APPLE_PASS_ICON_PATH")),
        "icon@2x.png" => File.binread(ENV.fetch("APPLE_PASS_ICON_PATH"))
      }
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

    private

    attr_reader :ticket

    def pass_payload
      event = ticket.event
      {
        formatVersion: 1,
        passTypeIdentifier: ENV.fetch("APPLE_PASS_TYPE_IDENTIFIER"),
        serialNumber: "ticket-#{ticket.id}-v#{ticket.scan_credential_version}",
        teamIdentifier: ENV.fetch("APPLE_TEAM_IDENTIFIER"),
        organizationName: "HafaPass",
        description: "Ticket for #{event.title}",
        logoText: "HafaPass",
        foregroundColor: "rgb(255, 255, 255)",
        backgroundColor: "rgb(14, 124, 123)",
        relevantDate: event.starts_at&.iso8601,
        expirationDate: (event.ends_at || event.starts_at)&.iso8601,
        voided: !ticket.admission_allowed?,
        eventTicket: {
          primaryFields: [{ key: "event", label: "EVENT", value: event.title }],
          secondaryFields: [
            { key: "date", label: "DATE", value: event.starts_at&.iso8601, dateStyle: "PKDateStyleMedium",
              timeStyle: "PKDateStyleShort" },
            { key: "venue", label: "VENUE", value: event.venue_name.to_s }
          ],
          auxiliaryFields: [
            { key: "ticket", label: "TICKET", value: ticket.ticket_type.name },
            (ticket.seat_label && { key: "seat", label: "SEAT", value: ticket.seat_label })
          ].compact,
          backFields: [
            { key: "holder", label: "TICKET HOLDER", value: ticket.attendee_name.to_s },
            { key: "address", label: "VENUE ADDRESS", value: event.venue_address.to_s }
          ]
        },
        barcode: { format: "PKBarcodeFormatQR", message: ticket.scan_credential,
          messageEncoding: "iso-8859-1", altText: "HafaPass #{ticket.id}" },
        barcodes: [{ format: "PKBarcodeFormatQR", message: ticket.scan_credential,
          messageEncoding: "iso-8859-1", altText: "HafaPass #{ticket.id}" }]
      }.compact
    end

    def signature(manifest)
      p12 = OpenSSL::PKCS12.new(
        Base64.strict_decode64(ENV.fetch("APPLE_PASS_CERTIFICATE_BASE64")),
        ENV.fetch("APPLE_PASS_CERTIFICATE_PASSWORD", "")
      )
      wwdr = OpenSSL::X509::Certificate.new(Base64.strict_decode64(ENV.fetch("APPLE_WWDR_CERTIFICATE_BASE64")))
      OpenSSL::PKCS7.sign(p12.certificate, p12.key, manifest, [wwdr],
        OpenSSL::PKCS7::BINARY | OpenSSL::PKCS7::DETACHED).to_der
    end
  end
end
