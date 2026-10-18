# frozen_string_literal: true

require "digest"

class MessageWirePayload
  class Unavailable < StandardError; end
  LEGACY_PROFILE = "hafapass_6b_resend_v1"
  LEGACY_KEYS = %w[from to subject html reply_to tags].freeze
  # Rails' original SDK Hash#to_json escaped these characters by default.
  # Pin that known profile without consulting mutable ActiveSupport settings.
  LEGACY_ESCAPES = { "<" => '\u003c', ">" => '\u003e', "&" => '\u0026',
    "\u2028" => '\u2028', "\u2029" => '\u2029' }.freeze
  LEGACY_TAGS = %w[order_confirmation order_recovery event_change ticket_delivery refund_notification
    guest_list waitlist_notification ticket_transfer waitlist_offer communication_campaign event_reminder].freeze

  # The SDK still owns headers, HTTP and typed errors. Only this request value's
  # serializer returns the durable bytes rather than re-encoding a JSONB Hash.
  class SdkHash < Hash
    def initialize(payload, wire_body)
      super()
      update(payload)
      @wire_body = wire_body.dup.freeze
    end

    def to_json(*)
      @wire_body
    end
  end

  class << self
    def prepare(delivery, payload)
      if delivery.outbound_wire_body.present? || delivery.wire_body_digest.present?
        verify!(delivery, payload)
        return { outbound_wire_body: delivery.outbound_wire_body, wire_body_digest: delivery.wire_body_digest }
      end
      if delivery.provider_attempted_at.present? || (delivery.provider == "resend" && delivery.attempts.positive?)
        raise Unavailable, "Original email wire bytes require verified legacy hydration or reconciliation"
      end

      body = JSON.generate(payload)
      { outbound_wire_body: body, wire_body_digest: Digest::SHA256.hexdigest(body) }
    end

    def for_delivery(delivery)
      unless delivery.persisted? && !delivery.has_changes_to_save? && delivery.attempts.positive? &&
          delivery.provider_attempted_at.present? && delivery.provider_outcome_unknown? &&
          delivery.send_lease_token.present? && delivery.send_lease_expires_at&.future?
        raise Unavailable, "A durable active send attempt is required"
      end
      verify!(delivery, delivery.outbound_payload)
      SdkHash.new(delivery.outbound_payload, delivery.outbound_wire_body)
    end

    def verify!(delivery, payload)
      body = delivery.outbound_wire_body
      unless body.present? && delivery.wire_body_digest == Digest::SHA256.hexdigest(body) && JSON.parse(body) == payload
        raise Unavailable, "The original email wire body or digest is unavailable or inconsistent"
      end
    rescue JSON::ParserError
      raise Unavailable, "The original email wire body is invalid"
    end

    # Explicit operator operation after the provider has independently confirmed
    # these exact bytes/key against its original request. No automated guessing.
    def hydrate_legacy!(delivery, profile:, verified_wire_body:, verified_wire_digest:)
      unless profile == LEGACY_PROFILE && verified_wire_body.is_a?(String) &&
          verified_wire_digest.to_s.match?(/\A[0-9a-f]{64}\z/) &&
          Digest::SHA256.hexdigest(verified_wire_body) == verified_wire_digest
        raise Unavailable, "Verified original wire bytes and their digest are required"
      end
      verified_wire_body = verified_wire_body.dup.force_encoding(Encoding::UTF_8)
      raise Unavailable, "Original email wire bytes must be valid UTF-8" unless verified_wire_body.valid_encoding?

      delivery.with_lock do
        if delivery.provider != "resend" || delivery.provider_id.present? || !delivery.attempts.positive? || !delivery.provider_outcome_unknown? ||
            %w[sent delivered bounced complained suppressed cancelled].include?(delivery.status) ||
            delivery.outbound_payload.blank? || delivery.outbound_wire_body.present? || delivery.wire_body_digest.present? ||
            delivery.provider_replay_expired? || (delivery.send_lease_expires_at && delivery.send_lease_expires_at > Time.current)
          raise Unavailable, "Legacy wire hydration requires an unreconciled, inactive request within its replay window"
        end
        EmailService.verify_transport_context!(delivery)
        payload = delivery.outbound_payload
        unless delivery.payload_digest == Digest::SHA256.hexdigest(JSON.generate(payload.sort.to_h)) &&
            payload["to"] == delivery.recipient
          raise Unavailable, "The frozen legacy payload is inconsistent"
        end
        body = legacy_body(payload)
        unless body == verified_wire_body
          raise Unavailable, "Verified wire bytes do not match the documented original schema and encoder"
        end
        delivery.update!(outbound_wire_body: body, wire_body_digest: verified_wire_digest)
      end
      delivery
    end

    private

    def legacy_body(payload)
      required = %w[from to subject html tags]
      valid_strings = %w[from to subject html].all? { |key| payload[key].is_a?(String) && payload[key].present? }
      valid_reply = !payload.key?("reply_to") || (payload["reply_to"].is_a?(String) && payload["reply_to"].present?)
      tags = payload["tags"]
      valid_tag = tags.is_a?(Array) && tags.one? && tags.first.is_a?(Hash) &&
        tags.first.keys.sort == %w[name value] && tags.first["name"] == "category" && LEGACY_TAGS.include?(tags.first["value"])
      unless (required - payload.keys).empty? && (payload.keys - LEGACY_KEYS).empty? && valid_strings && valid_reply && valid_tag
        raise Unavailable, "Legacy payload is outside the documented original email schema"
      end

      ordered = LEGACY_KEYS.each_with_object({}) { |key, result| result[key] = payload.fetch(key) if payload.key?(key) }
      ordered["tags"] = [{ "name" => tags.first.fetch("name"), "value" => tags.first.fetch("value") }]
      JSON.generate(ordered).gsub(/[<>&\u2028\u2029]/, LEGACY_ESCAPES)
    end
  end
end
