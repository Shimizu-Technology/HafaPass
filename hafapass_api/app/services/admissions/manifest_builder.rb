# frozen_string_literal: true

require "digest"

module Admissions
  class ManifestBuilder
    class ManifestError < StandardError; end

    MAX_LIFETIME = 24.hours
    EVENT_GRACE = 12.hours
    SCHEMA_VERSION = 2

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
          schema_version: SCHEMA_VERSION,
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
        "{#{value.stringify_keys.sort.map { |key, item| "#{JSON.generate(key)}:#{canonical_json(item)}" }.join(",")}}"
      when Array
        "[#{value.map { |item| canonical_json(item) }.join(",")}]"
      else
        # Explicit protocol encoding matches browser JSON.stringify; Rails'
        # HTML-safe escaping would change manifest digest/signature bytes.
        JSON.generate(value)
      end
    end

    private

    attr_reader :event, :actor

    def manifest_tickets
      re_entry_enabled = event.re_entry_enabled?
      preloads = [
        :ticket_type, :inventory_retention, :pending_refund_tickets,
        { parent_ticket: [:pending_refund_tickets, :inventory_retention] },
        { order: [:disputes, :refunds, :payments, { registration_responses: :registration_question }] },
        { event_seat: { venue_seat: { seating_row: :seating_section } } }
      ]
      preloads << :last_entry_device if re_entry_enabled

      event.tickets.scannable.preload(*preloads).order(:id).map do |ticket|
        entry = {
          ticket_id: ticket.id,
          code: "HP-T#{ticket.id}",
          credential_hash: Digest::SHA256.hexdigest(ticket.scan_credential),
          ticket_type: [ticket.ticket_type.name, ticket.seat_label].compact.join(" · "),
          seat: ticket.seat_label,
          state: admission_state(ticket),
          reversed_admission_action_uuids: reversed_admissions_by_ticket.fetch(ticket.id, [])
        }
        if re_entry_enabled
          entry.merge!(
            occupancy_state: ticket.occupancy_state,
            occupancy_day: ticket.occupancy_day&.iso8601,
            last_entry_at: ticket.last_entry_at&.iso8601(6),
            last_entry_gate: ticket.last_entry_device&.name,
            last_exit_at: ticket.last_exit_at&.iso8601(6),
            re_entry_count: ticket.re_entry_count,
            re_entry_conflict_flagged: ticket.re_entry_conflict_flagged
          )
        end
        entry.merge(DoorPayload.call(ticket))
      end
    end

    def reversed_admissions_by_ticket
      @reversed_admissions_by_ticket ||= event.admission_actions.kind_reverse.result_accepted
        .joins(<<~SQL.squish)
          INNER JOIN admission_actions reversed_admissions
          ON reversed_admissions.id = admission_actions.reverses_action_id
          AND reversed_admissions.ticket_id = admission_actions.ticket_id
        SQL
        .where(reversed_admissions: { event_id: event.id, kind: AdmissionAction.kinds.fetch("admit"),
          result: AdmissionAction.results.fetch("accepted") })
        .pluck(:ticket_id, "reversed_admissions.action_uuid")
        .group_by(&:first).transform_values { |entries| entries.map(&:last).uniq.sort }
    end

    def admission_state(ticket)
      reason = ticket.admission_block_reason(payment_mode: payment_mode)
      return "valid" if reason.nil?
      return "admitted" if reason == "not_admissible" && ticket.checked_in?
      return "invalid" if reason == "not_admissible" || reason == "event_unavailable"

      reason
    end

    def event_payload
      base = {
        id: event.id,
        title: event.title,
        status: event.status,
        venue_name: event.venue_name,
        starts_at: event.starts_at&.iso8601(6),
        ends_at: event.ends_at&.iso8601(6),
        timezone: event.timezone
      }
      return base unless event.re_entry_enabled?

      base.merge(
        doors_open_at: event.doors_open_at&.iso8601(6),
        re_entry_mode: event.re_entry_mode,
        re_entry_max_count: event.re_entry_max_count,
        re_entry_cutoff_time: event.re_entry_cutoff_time,
        re_entry_cooldown_minutes: event.re_entry_cooldown_minutes,
        re_entry_rollover_hour: event.re_entry_rollover_hour
      )
    end

    # The payment mode decides whether test-card tickets admit people, so a
    # mode switch yields a new manifest version and scanners re-download it.
    def source_payload(tickets)
      { schema_version: SCHEMA_VERSION, event: event_payload, payment_mode: payment_mode, tickets: tickets }
    end

    def payment_mode
      @payment_mode ||= SiteSetting.instance.payment_mode
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
