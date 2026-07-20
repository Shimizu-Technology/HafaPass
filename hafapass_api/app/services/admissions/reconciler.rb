# frozen_string_literal: true

require "digest"

module Admissions
  class Reconciler
    class SyncError < StandardError; end

    Result = Data.define(:action, :ticket)
    FUTURE_TOLERANCE = 5.minutes
    MAX_BATCH_SIZE = 500
    CLIENT_KINDS = %w[admit reverse].freeze
    CLIENT_SOURCES = %w[online offline].freeze

    def self.call(**)
      new(**).call
    end

    def initialize(device:, actor:, actions:, request: nil)
      @device = device
      @actor = actor
      @actions = actions
      @request = request
    end

    def call
      validate_batch!
      results = normalized_actions.sort_by { |action| action.fetch(:sequence) }.map { |action| reconcile(action) }
      device.update!(
        last_sequence: [device.last_sequence, results.filter_map { |result| result.action.sequence }.max.to_i].max,
        last_synced_at: Time.current,
        last_seen_at: Time.current
      )
      results
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      raise SyncError, e.message
    end

    private

    attr_reader :device, :actor, :actions, :request

    def validate_batch!
      raise SyncError, "actions must be a non-empty array" unless actions.is_a?(Array) && actions.any?
      raise SyncError, "A sync batch cannot exceed #{MAX_BATCH_SIZE} actions" if actions.size > MAX_BATCH_SIZE
      raise SyncError, "Scanner device does not belong to this user" unless device.user_id == actor.id
      raise SyncError, "Scanner device authorization has expired or was revoked" unless device.effective?
      unless OrganizationAuthorization.allowed?(
        user: actor,
        organization: device.organization,
        permission: :scan,
        event: device.event
      )
        raise SyncError, "Scanner assignment is no longer active"
      end
    end

    def normalized_actions
      @normalized_actions ||= actions.map do |raw|
        raise SyncError, "Each action must be an object" unless raw.respond_to?(:to_h)

        action = raw.to_h.symbolize_keys
        sequence = Integer(action[:sequence], exception: false)
        manifest_version = Integer(action[:manifest_version], exception: false)
        occurred_at = Time.zone.parse(action[:occurred_at].to_s)
        raise SyncError, "Each action requires an action_uuid" if action[:action_uuid].blank?
        raise SyncError, "Each action_uuid is too long" if action[:action_uuid].to_s.length > 128
        raise SyncError, "Each action requires a positive sequence" unless sequence&.positive?
        raise SyncError, "Each action requires a positive manifest_version" unless manifest_version&.positive?
        raise SyncError, "Each action requires a valid occurred_at" unless occurred_at

        kind = action[:kind].to_s
        source = action[:source].to_s
        raise SyncError, "Each action requires a valid kind" unless CLIENT_KINDS.include?(kind)
        raise SyncError, "Each action requires a valid source" unless CLIENT_SOURCES.include?(source)
        if action[:client_status].present? &&
            (!action[:client_status].is_a?(String) || action[:client_status].length > 64)
          raise SyncError, "Each client_status must be a short string"
        end
        if kind == "admit"
          raise SyncError, "Each admission requires a ticket_id" unless Integer(action[:ticket_id], exception: false)&.positive?
          unless action[:credential_hash].to_s.match?(/\A[0-9a-f]{64}\z/)
            raise SyncError, "Each admission requires a SHA-256 credential hash"
          end
        elsif action[:reverses_action_uuid].blank?
          raise SyncError, "Each reversal requires reverses_action_uuid"
        end

        action.merge(kind: kind, source: source, sequence: sequence, manifest_version: manifest_version,
          occurred_at: occurred_at)
      rescue ArgumentError, TypeError
        raise SyncError, "Each action requires a valid occurred_at"
      end.tap do |normalized|
        raise SyncError, "Action UUIDs must be unique within a sync batch" unless normalized.pluck(:action_uuid).uniq.size == normalized.size
        raise SyncError, "Device sequences must be unique within a sync batch" unless normalized.pluck(:sequence).uniq.size == normalized.size
      end
    end

    def reconcile(input)
      existing = AdmissionAction.find_by(action_uuid: input.fetch(:action_uuid))
      return validate_replay!(existing, input) if existing
      if input.fetch(:sequence) <= device.last_sequence
        raise SyncError, "Device sequence has already been synchronized"
      end

      AdmissionAction.transaction do
        device.lock!
        existing = AdmissionAction.find_by(action_uuid: input.fetch(:action_uuid))
        return validate_replay!(existing, input) if existing
        if input.fetch(:sequence) <= device.last_sequence
          raise SyncError, "Device sequence has already been synchronized"
        end

        input.fetch(:kind) == "reverse" ? reconcile_reversal(input) : reconcile_admission(input)
      end
    end

    def reconcile_admission(input)
      ticket, manifest_entry, rejection = resolve_ticket(input)
      return record_action(input, ticket: ticket, result: :rejected, reason_code: rejection) if rejection

      ticket.lock!
      if ticket.checked_in?
        return record_action(input, ticket: ticket, result: :conflict, reason_code: "already_admitted")
      end
      unless ticket.admission_allowed?
        return record_action(input, ticket: ticket, result: :rejected, reason_code: current_block_reason(ticket))
      end

      ticket.check_in!
      record_action(input, ticket: ticket, result: :accepted, reason_code: "admitted", entry: manifest_entry)
    end

    def reconcile_reversal(input)
      unless OrganizationAuthorization.allowed?(
        user: actor,
        organization: device.organization,
        permission: :manage_attendees,
        event: device.event
      )
        return record_action(input, result: :rejected, reason_code: "reversal_not_authorized", kind: :reverse)
      end

      original = AdmissionAction.find_by(action_uuid: input[:reverses_action_uuid])
      unless original&.event_id == device.event_id && original.kind_admit? && original.result_accepted?
        return record_action(input, result: :rejected, reason_code: "admission_not_found", kind: :reverse)
      end
      ticket = original.ticket
      ticket.lock!
      if original.reversal_action.present?
        return record_action(input, ticket: ticket, result: :conflict, reason_code: "already_reversed",
          kind: :reverse, reverses_action: original)
      end
      unless ticket.checked_in?
        return record_action(input, ticket: ticket, result: :conflict, reason_code: "ticket_not_admitted",
          kind: :reverse, reverses_action: original)
      end

      ticket.reverse_check_in!
      record_action(input, ticket: ticket, result: :accepted, reason_code: "admission_reversed",
        kind: :reverse, reverses_action: original)
    end

    def resolve_ticket(input)
      version = input.fetch(:manifest_version)
      manifest = manifest_for(version)
      return [nil, nil, "manifest_not_found"] unless manifest
      occurred_at = input.fetch(:occurred_at)
      return [nil, nil, "manifest_not_active"] if occurred_at < manifest.generated_at || occurred_at >= manifest.expires_at
      return [nil, nil, "scan_time_invalid"] if occurred_at > Time.current + FUTURE_TOLERANCE
      return [nil, nil, "device_authorization_expired"] if occurred_at >= device.authorization_expires_at

      entry = entries_for(manifest)[input[:ticket_id].to_i]
      entry = nil unless entry && secure_equal?(entry["credential_hash"], input[:credential_hash])
      return [nil, nil, "credential_not_in_manifest"] unless entry

      ticket = device.event.tickets.includes(:ticket_type, order: :disputes).find_by(id: entry["ticket_id"])
      return [nil, entry, "ticket_not_found"] unless ticket

      current_hash = Digest::SHA256.hexdigest(ticket.scan_credential)
      return [ticket, entry, "credential_revoked"] unless secure_equal?(current_hash, input[:credential_hash])

      [ticket, entry, nil]
    end

    def manifest_for(version)
      @manifests_by_version ||= {}
      return @manifests_by_version[version] if @manifests_by_version.key?(version)

      @manifests_by_version[version] = device.event.admission_manifests.find_by(version: version)
    end

    def entries_for(manifest)
      @entries_by_manifest ||= {}
      @entries_by_manifest[manifest.id] ||= Array(manifest.payload["tickets"]).index_by do |entry|
        entry["ticket_id"].to_i
      end
    end

    def record_action(input, ticket: nil, result:, reason_code:, kind: :admit, entry: nil, reverses_action: nil)
      action = AdmissionAction.create!(
        organization: device.organization,
        event: device.event,
        ticket: ticket,
        scanner_device: device,
        actor_user: actor,
        reverses_action: reverses_action,
        action_uuid: input.fetch(:action_uuid),
        kind: kind,
        source: input.fetch(:source),
        result: result,
        reason_code: reason_code,
        credential_hash: input[:credential_hash],
        manifest_version: input.fetch(:manifest_version),
        sequence: input.fetch(:sequence),
        occurred_at: input.fetch(:occurred_at),
        received_at: Time.current,
        attendee_snapshot: attendee_snapshot(ticket, entry),
        metadata: { client_status: input[:client_status] }.compact
      )
      AuditLogger.record!(
        action: kind == :reverse ? "ticket.check_in_reversed" : "ticket.admission_reconciled",
        auditable: action,
        actor: actor,
        organization: device.organization,
        after_data: { result: action.result, reason_code: action.reason_code, ticket_id: ticket&.id },
        request: request
      )
      Result.new(action: action, ticket: ticket)
    end

    def attendee_snapshot(ticket, entry)
      return {} unless ticket || entry

      {
        code: entry&.fetch("code", nil) || "HP-T#{ticket.id}",
        attendee_name: entry&.fetch("attendee_name", nil) || ticket&.attendee_name,
        ticket_type: entry&.fetch("ticket_type", nil) || ticket&.ticket_type&.name
      }.compact
    end

    def current_block_reason(ticket)
      return "cancelled" if ticket.cancelled?
      return "transferred" if ticket.transferred?
      return "payment_blocked" if ticket.order.ticket_access_blocked?
      return "unfulfilled" unless ticket.order.ticket_fulfilled?
      return "event_unavailable" unless ticket.event.published?

      "not_admissible"
    end

    def validate_replay!(existing, input)
      unless existing.scanner_device_id == device.id && existing.event_id == device.event_id &&
          existing.sequence == input.fetch(:sequence) && existing.kind == input.fetch(:kind) &&
          existing.source == input.fetch(:source) && existing.credential_hash == input[:credential_hash] &&
          existing.reverses_action&.action_uuid == input[:reverses_action_uuid]
        raise SyncError, "action_uuid was already used for a different admission action"
      end

      Result.new(action: existing, ticket: existing.ticket)
    end

    def secure_equal?(left, right)
      left.present? && right.present? && left.bytesize == right.bytesize &&
        ActiveSupport::SecurityUtils.secure_compare(left, right)
    end
  end
end
