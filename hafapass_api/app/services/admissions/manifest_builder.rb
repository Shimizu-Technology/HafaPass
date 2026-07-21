# frozen_string_literal: true

require "digest"

module Admissions
  class ManifestBuilder
    class ManifestError < StandardError; end

    MAX_LIFETIME = 24.hours
    EVENT_GRACE = 12.hours

    def self.call(**)
      new(**).call
    end

    def initialize(event:, actor:)
      @event = event
      @actor = actor
    end

    def call
      manifest = nil
      AdmissionManifest.transaction do
        event.lock!
        raise ManifestError, "Only published events can issue scanner manifests" unless event.published?

        tickets = manifest_tickets
        source_digest = digest_for(source_payload(tickets))
        manifest = event.admission_manifests.order(version: :desc).first
        if manifest&.source_digest == source_digest && manifest.key_id == ManifestSigner.key_id && !manifest.expired?
          next
        end

        version = manifest ? manifest.version + 1 : 1
        generated_at = Time.current
        expires_at = manifest_expiration(generated_at)
        payload = {
          schema_version: 1,
          event: event_payload,
          version: version,
          generated_at: generated_at.iso8601(6),
          expires_at: expires_at.iso8601(6),
          tickets: tickets
        }
        digest = digest_for(payload)
        manifest = event.admission_manifests.create!(
          organization: event.organization,
          generated_by_user: actor,
          version: version,
          source_digest: source_digest,
          digest: digest,
          signature: ManifestSigner.sign(digest),
          key_id: ManifestSigner.key_id,
          algorithm: ManifestSigner::ALGORITHM,
          payload: payload,
          ticket_count: tickets.length,
          generated_at: generated_at,
          expires_at: expires_at
        )
      end
      manifest
    rescue ActiveRecord::RecordInvalid => e
      raise ManifestError, e.record.errors.full_messages.to_sentence
    end

    def self.canonical_json(value)
      case value
      when Hash
        "{#{value.stringify_keys.sort.map { |key, item| "#{key.to_json}:#{canonical_json(item)}" }.join(",")}}"
      when Array
        "[#{value.map { |item| canonical_json(item) }.join(",")}]"
      else
        value.to_json
      end
    end

    private

    attr_reader :event, :actor

    def manifest_tickets
      event.tickets.includes(:ticket_type, { order: :disputes },
        event_seat: { venue_seat: { seating_row: :seating_section } }).order(:id).map do |ticket|
        {
          ticket_id: ticket.id,
          code: "HP-T#{ticket.id}",
          credential_hash: Digest::SHA256.hexdigest(ticket.scan_credential),
          attendee_name: ticket.attendee_name.presence || "Guest",
          ticket_type: [ticket.ticket_type.name, ticket.seat_label].compact.join(" · "),
          seat: ticket.seat_label,
          state: admission_state(ticket)
        }
      end
    end

    def admission_state(ticket)
      return "cancelled" if ticket.cancelled?
      return "transferred" if ticket.transferred?
      return "payment_blocked" if ticket.order.ticket_access_blocked?
      return "unfulfilled" unless ticket.order.ticket_fulfilled?
      return "admitted" if ticket.checked_in?
      return "valid" if ticket.issued?

      "invalid"
    end

    def event_payload
      {
        id: event.id,
        title: event.title,
        status: event.status,
        venue_name: event.venue_name,
        starts_at: event.starts_at&.iso8601(6),
        ends_at: event.ends_at&.iso8601(6),
        timezone: event.timezone
      }
    end

    def source_payload(tickets)
      { event: event_payload, tickets: tickets }
    end

    def digest_for(value)
      Digest::SHA256.hexdigest(self.class.canonical_json(value))
    end

    def manifest_expiration(generated_at)
      event_limit = (event.ends_at || event.starts_at)&.+(EVENT_GRACE)
      expiration = [generated_at + MAX_LIFETIME, event_limit].compact.min
      raise ManifestError, "The event admission window has ended" unless expiration > generated_at

      expiration
    end
  end
end
