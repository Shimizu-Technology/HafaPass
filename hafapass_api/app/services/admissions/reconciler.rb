# frozen_string_literal: true

require "digest"

module Admissions
  class Reconciler
    class SyncError < StandardError; end

    Result = Data.define(:action, :ticket)
    FUTURE_TOLERANCE = 5.minutes
    # Phone clocks across separate door scanners routinely drift by 5–60 seconds.
    # Online scans are decided in real time by the server, so we never reject them
    # on client-clock ordering against another scanner's timestamp. Offline scans
    # only conflict as out-of-order when they predate the opposite transition by
    # more than this tolerance.
    CLOCK_SKEW_TOLERANCE = 2.minutes
    MAX_BATCH_SIZE = 500
    CLIENT_KINDS = %w[admit reverse exit].freeze
    CLIENT_SOURCES = %w[online offline].freeze

    def self.call(**)
      AuditContext.set(fail_open: true) { new(**).call }
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
      device.with_lock do
        device.update!(
          last_sequence: [device.last_sequence, results.filter_map { |result| result.action.sequence }.max.to_i].max,
          last_synced_at: Time.current,
          last_seen_at: Time.current
        )
      end
      results
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      raise SyncError, e.message
    end

    # Online scans inspect live eligibility before the browser journals an
    # admission or exit. A hold consumes neither an action UUID nor a device sequence.
    def preview(ticket_id:, credential_hash:, manifest_version:, kind: "admit")
      kind = kind.to_s.presence || "admit"
      unless %w[admit exit].include?(kind)
        return { status: "rejected", reason_code: "invalid_scan_kind" }
      end

      ticket_id = Integer(ticket_id, exception: false)
      unless ticket_id&.positive? && credential_hash.is_a?(String) && credential_hash.match?(/\A[0-9a-f]{64}\z/)
        return { status: "rejected", reason_code: "credential_not_in_manifest" }
      end

      AdmissionAction.transaction do
        lock_admission_context!
        validate_authorization!
        input = {
          kind: kind,
          source: "online",
          ticket_id: ticket_id,
          credential_hash: credential_hash,
          manifest_version: Integer(manifest_version, exception: false),
          occurred_at: Time.current
        }
        ticket, entry, rejection = resolve_ticket(input)
        return { status: "rejected", reason_code: rejection } if rejection

        if device.event.re_entry_enabled?
          preview_re_entry(ticket, entry, input)
        else
          preview_standard(ticket, entry, input)
        end
      end
    end

    private

    attr_reader :device, :actor, :actions, :request

    def preview_standard(ticket, entry, input)
      return { status: "rejected", reason_code: "re_entry_disabled" } if input[:kind] == "exit"

      reason = lock_and_check_ticket(ticket, input)
      return { status: "rejected", reason_code: reason } if reason

      verification_required = verification_required?(ticket, entry, "online")
      {
        status: verification_required ? "verification_required" : "ready",
        verification_required: verification_required,
        ticket: preview_ticket_payload(ticket, entry, verification_required: verification_required)
      }
    end

    def preview_re_entry(ticket, entry, input)
      decision = lock_and_evaluate_re_entry(ticket, input)
      unless decision[:result] == :accepted
        return {
          status: "rejected",
          reason_code: decision[:reason_code],
          details: decision[:details],
          ticket: preview_ticket_payload(ticket, entry, verification_required: false)
        }
      end

      if input[:kind] == "exit"
        return {
          status: "ready",
          verification_required: false,
          action_kind: "exit",
          ticket: preview_ticket_payload(ticket, entry, verification_required: false)
        }
      end

      is_re_entry = decision[:details][:re_entry] == true
      verification_required = !is_re_entry && verification_required?(ticket, entry, "online")
      {
        status: verification_required ? "verification_required" : "ready",
        verification_required: verification_required,
        re_entry: is_re_entry,
        re_entry_number: decision[:details][:re_entry_number].to_i,
        ticket: preview_ticket_payload(ticket, entry, verification_required: verification_required)
      }
    end

    def preview_ticket_payload(ticket, entry, verification_required:)
      DoorPayload.call(ticket).merge(
        ticket_id: ticket.id,
        code: "HP-T#{ticket.id}",
        seat: ticket.seat_label,
        ticket_type: entry["ticket_type"],
        door_check_mode: verification_required ? "verify" : "instant",
        occupancy_state: ticket.occupancy_state,
        occupancy_day: ticket.occupancy_day&.iso8601,
        re_entry_count: ticket.re_entry_count
      )
    end

    def validate_batch!
      raise SyncError, "actions must be a non-empty array" unless actions.is_a?(Array) && actions.any?
      raise SyncError, "A sync batch cannot exceed #{MAX_BATCH_SIZE} actions" if actions.size > MAX_BATCH_SIZE
      validate_authorization!
    end

    def validate_authorization!
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
        if %w[admit exit].include?(kind)
          raise SyncError, "Each #{kind} action requires a ticket_id" unless Integer(action[:ticket_id], exception: false)&.positive?
          unless action[:credential_hash].to_s.match?(/\A[0-9a-f]{64}\z/)
            raise SyncError, "Each #{kind} action requires a SHA-256 credential hash"
          end
        elsif action[:reverses_action_uuid].blank? || action[:reverses_action_uuid].to_s.length > 128
          raise SyncError, "Each reversal requires a valid reverses_action_uuid"
        end

        action.merge(kind: kind, source: source, sequence: sequence, manifest_version: manifest_version,
          occurred_at: occurred_at, confirmed: kind == "admit" && action[:confirmed] == true)
      rescue ArgumentError, TypeError
        raise SyncError, "Each action requires a valid occurred_at"
      end.tap do |normalized|
        raise SyncError, "Action UUIDs must be unique within a sync batch" unless normalized.pluck(:action_uuid).uniq.size == normalized.size
        raise SyncError, "Device sequences must be unique within a sync batch" unless normalized.pluck(:sequence).uniq.size == normalized.size
      end
    end

    def reconcile(input)
      AdmissionAction.transaction do
        lock_admission_context!
        validate_authorization!
        existing = AdmissionAction.find_by(action_uuid: input.fetch(:action_uuid))
        return validate_replay!(existing, input) if existing
        if input.fetch(:sequence) <= device.last_sequence
          raise SyncError, "Device sequence has already been synchronized"
        end

        case input.fetch(:kind)
        when "reverse" then reconcile_reversal(input)
        when "exit" then reconcile_exit(input)
        else reconcile_admission(input)
        end
      end
    end

    def lock_admission_context!
      # Staff mutations/invitation quotas start at ACTOR, then ORG. Downloads
      # start at ORG/EVENT, then SCANNER. Take both prefixes before the device
      # or grant rows; admission/audit inserts also need parent FK key shares.
      # NO KEY UPDATE permits those references, but conflicts with another
      # actor lock. It must never be acquired after the device/parent locks.
      actor.lock!("FOR NO KEY UPDATE")
      # This still excludes staff/tenant mutations' strong parent locks, but
      # permits event-first commerce's audit FK while we wait for EVENT.
      device.organization.lock!("FOR NO KEY UPDATE")
      device.event.lock!
      device.lock!
      device.organization.organization_memberships.where(user_id: actor.id).order(:id).lock.load
      device.event.event_staff_assignments.where(user_id: actor.id).order(:id).lock.load
    end

    def reconcile_admission(input)
      ticket, manifest_entry, rejection = resolve_ticket(input)
      if rejection
        return record_action(input, ticket: ticket, result: :rejected, reason_code: rejection)
      end

      return reconcile_re_entry_admission(ticket, manifest_entry, input) if device.event.re_entry_enabled?

      reason = lock_and_check_ticket(ticket, input)
      if reason
        result = reason == "already_admitted" ? :conflict : :rejected
        return record_action(input, ticket: ticket, result: result, reason_code: reason)
      end
      if verification_required?(ticket, manifest_entry, input[:source]) && !input[:confirmed]
        return record_action(input, ticket: ticket, result: :rejected, reason_code: "verification_required")
      end

      ticket.check_in!(occurred_at: input.fetch(:occurred_at), device: device)
      record_action(input, ticket: ticket, result: :accepted, reason_code: "admitted", entry: manifest_entry)
    end

    def reconcile_re_entry_admission(ticket, manifest_entry, input)
      decision = lock_and_evaluate_re_entry(ticket, input)
      details = decision[:details]

      unless decision[:result] == :accepted
        apply_conflict_side_effects!(ticket, input, decision)
        return record_action(input, ticket: ticket, result: decision[:result], reason_code: decision[:reason_code],
          entry: manifest_entry, extra_metadata: details)
      end

      is_re_entry = details[:re_entry] == true
      if !is_re_entry && verification_required?(ticket, manifest_entry, input[:source]) && !input[:confirmed]
        return record_action(input, ticket: ticket, result: :rejected, reason_code: "verification_required",
          entry: manifest_entry)
      end

      scan_day = device.event.occupancy_day_for(input.fetch(:occurred_at))
      if ticket.occupancy_day.present? && scan_day < ticket.occupancy_day
        # Prior-day offline entry reconciled after a later day already ran: record without clobbering today's state.
        if !ticket.checked_in?
          ticket.check_in!(occurred_at: input.fetch(:occurred_at), device: device)
        end
      elsif !ticket.checked_in?
        ticket.check_in!(occurred_at: input.fetch(:occurred_at), device: device)
      else
        ticket.record_re_entry!(occurred_at: input.fetch(:occurred_at), device: device, day: scan_day)
      end

      record_action(input, ticket: ticket, result: :accepted, reason_code: decision[:reason_code],
        entry: manifest_entry, extra_metadata: details)
    end

    def reconcile_exit(input)
      ticket, manifest_entry, rejection = resolve_ticket(input)
      if rejection
        return record_action(input, ticket: ticket, result: :rejected, reason_code: rejection, kind: :exit)
      end

      unless device.event.re_entry_enabled?
        return record_action(input, ticket: ticket, result: :rejected, reason_code: "re_entry_disabled",
          kind: :exit, entry: manifest_entry)
      end

      decision = lock_and_evaluate_re_entry(ticket, input)
      unless decision[:result] == :accepted
        apply_conflict_side_effects!(ticket, input, decision)
        return record_action(input, ticket: ticket, result: decision[:result], reason_code: decision[:reason_code],
          kind: :exit, entry: manifest_entry, extra_metadata: decision[:details])
      end

      scan_day = device.event.occupancy_day_for(input.fetch(:occurred_at))
      unless ticket.occupancy_day.present? && scan_day < ticket.occupancy_day
        ticket.record_exit!(occurred_at: input.fetch(:occurred_at), day: scan_day)
      end

      record_action(input, ticket: ticket, result: :accepted, reason_code: "exited",
        kind: :exit, entry: manifest_entry, extra_metadata: decision[:details])
    end

    def apply_conflict_side_effects!(ticket, input, decision)
      return unless decision[:flag_conflict] || decision[:win_by_occurred_at]

      updates = {}
      updates[:re_entry_conflict_flagged] = true if decision[:flag_conflict]
      if decision[:win_by_occurred_at]
        updates[:last_entry_at] = input.fetch(:occurred_at)
        updates[:last_entry_device_id] = device.id
      end
      ticket.update!(updates) if updates.any?
    end

    def lock_and_check_ticket(ticket, input)
      ticket.order.lock!
      ticket.lock!
      # Authorization may expire while the ticket/order lock is contended.
      validate_authorization!
      unless secure_equal?(Digest::SHA256.hexdigest(ticket.scan_credential), input[:credential_hash])
        return "credential_revoked"
      end
      return "already_admitted" if ticket.checked_in?

      ticket.admission_block_reason
    end

    def lock_and_evaluate_re_entry(ticket, input)
      ticket.order.lock!
      ticket.lock!
      validate_authorization!
      unless secure_equal?(Digest::SHA256.hexdigest(ticket.scan_credential), input[:credential_hash])
        return { result: :rejected, reason_code: "credential_revoked", details: {} }
      end

      block = ticket.admission_block_reason(allow_checked_in: true)
      return { result: :rejected, reason_code: block, details: {} } if block

      event = device.event
      occurred_at = input.fetch(:occurred_at)
      scan_day = event.occupancy_day_for(occurred_at)

      if input[:kind] == "exit"
        evaluate_exit_decision(ticket, event, input, occurred_at, scan_day)
      else
        evaluate_entry_decision(ticket, event, input, occurred_at, scan_day)
      end
    end

    def evaluate_exit_decision(ticket, event, input, occurred_at, scan_day)
      unless event.re_entry_exit_scan?
        return { result: :rejected, reason_code: "re_entry_exit_not_used", details: {} }
      end

      if ticket.occupancy_day.present? && scan_day < ticket.occupancy_day
        return evaluate_historical_day_exit(ticket, input, occurred_at, scan_day)
      end

      unless ticket.effective_occupancy_state(day: scan_day) == "inside"
        return {
          result: :conflict,
          reason_code: "not_inside",
          details: {
            occupancy_state: ticket.effective_occupancy_state(day: scan_day),
            last_exit_at: ticket.last_exit_at&.iso8601(6)
          }.compact
        }
      end

      if input[:source] == "offline" && ticket.last_entry_at.present? && occurred_at < (ticket.last_entry_at - CLOCK_SKEW_TOLERANCE)
        return {
          result: :conflict,
          reason_code: "exit_before_latest_entry",
          flag_conflict: true,
          details: {
            prior_entry_at: ticket.last_entry_at.iso8601(6),
            prior_gate_name: ticket.last_entry_device&.name,
            offline_conflict: true
          }.compact
        }
      end

      { result: :accepted, reason_code: "exited", details: { gate_name: device.name } }
    end

    def evaluate_entry_decision(ticket, event, input, occurred_at, scan_day)
      if ticket.occupancy_day.present? && scan_day < ticket.occupancy_day
        return evaluate_historical_day_entry(ticket, event, input, occurred_at, scan_day)
      end

      same_day = ticket.entered_on_day?(scan_day)
      effective_state = ticket.effective_occupancy_state(day: scan_day)
      effective_re_entries = ticket.effective_re_entry_count(day: scan_day)

      if event.re_entry_exit_scan?
        evaluate_exit_scan_entry(ticket, event, input, occurred_at, scan_day, same_day, effective_state, effective_re_entries)
      else
        evaluate_cooldown_entry(ticket, event, input, occurred_at, scan_day, same_day, effective_re_entries)
      end
    end

    def evaluate_exit_scan_entry(ticket, event, input, occurred_at, scan_day, same_day, effective_state, effective_re_entries)
      if effective_state == "inside"
        offline = input[:source] == "offline"
        earlier = offline && ticket.last_entry_at.present? && occurred_at < ticket.last_entry_at
        prior_gate = ticket.last_entry_device&.name
        return {
          result: :conflict,
          reason_code: "already_inside",
          flag_conflict: offline,
          win_by_occurred_at: earlier,
          details: {
            prior_entry_at: ticket.last_entry_at&.iso8601(6),
            prior_gate_name: prior_gate,
            prior_device_id: ticket.last_entry_device_id,
            offline_conflict: (true if offline),
            winner_by_occurred_at: (true if earlier)
          }.compact
        }
      end

      if same_day
        if input[:source] == "offline" && ticket.last_exit_at.present? && occurred_at < (ticket.last_exit_at - CLOCK_SKEW_TOLERANCE)
          return {
            result: :conflict,
            reason_code: "admit_before_latest_exit",
            flag_conflict: true,
            details: {
              last_exit_at: ticket.last_exit_at.iso8601(6),
              prior_entry_at: ticket.last_entry_at&.iso8601(6),
              prior_gate_name: ticket.last_entry_device&.name,
              offline_conflict: true
            }.compact
          }
        end

        cutoff_rejection = check_re_entry_cutoff(event, occurred_at, scan_day)
        return cutoff_rejection if cutoff_rejection

        cap_rejection = check_re_entry_cap(event, effective_re_entries)
        return cap_rejection if cap_rejection

        return {
          result: :accepted,
          reason_code: "re_entered",
          details: { re_entry: true, re_entry_number: effective_re_entries + 1, gate_name: device.name }
        }
      end

      { result: :accepted, reason_code: "admitted", details: { re_entry: false, re_entry_number: 0, gate_name: device.name } }
    end

    def evaluate_cooldown_entry(ticket, event, input, occurred_at, scan_day, same_day, effective_re_entries)
      unless same_day
        return { result: :accepted, reason_code: "admitted", details: { re_entry: false, re_entry_number: 0, gate_name: device.name } }
      end

      cooldown_minutes = event.re_entry_cooldown_minutes || 15
      cooldown_seconds = cooldown_minutes.minutes
      last_entry = ticket.last_entry_at
      elapsed = last_entry ? (occurred_at - last_entry) : cooldown_seconds

      if last_entry && (elapsed < cooldown_seconds)
        offline = input[:source] == "offline"
        earlier = offline && occurred_at < last_entry
        elapsed_min = [(elapsed / 60.0).floor, 0].max
        remaining_min = [((last_entry + cooldown_seconds - occurred_at) / 60.0).ceil, 1].max
        return {
          result: :conflict,
          reason_code: "cooldown_active",
          flag_conflict: offline,
          win_by_occurred_at: earlier,
          details: {
            prior_entry_at: last_entry.iso8601(6),
            prior_gate_name: ticket.last_entry_device&.name,
            prior_device_id: ticket.last_entry_device_id,
            cooldown_minutes: cooldown_minutes,
            elapsed_minutes: elapsed_min,
            remaining_minutes: remaining_min,
            retry_after_at: (last_entry + cooldown_seconds).iso8601(6),
            offline_conflict: (true if offline),
            winner_by_occurred_at: (true if earlier)
          }.compact
        }
      end

      cutoff_rejection = check_re_entry_cutoff(event, occurred_at, scan_day)
      return cutoff_rejection if cutoff_rejection

      cap_rejection = check_re_entry_cap(event, effective_re_entries)
      return cap_rejection if cap_rejection

      {
        result: :accepted,
        reason_code: "re_entered",
        details: { re_entry: true, re_entry_number: effective_re_entries + 1, gate_name: device.name }
      }
    end

    def evaluate_historical_day_entry(ticket, event, input, occurred_at, scan_day)
      day_actions = ticket.admission_actions.result_accepted.where(occupancy_day: scan_day).order(:occurred_at, :received_at, :id)
      last = day_actions.last
      if event.re_entry_exit_scan? && last&.kind_admit?
        return {
          result: :conflict,
          reason_code: "already_inside",
          flag_conflict: input[:source] == "offline",
          details: {
            prior_entry_at: last.occurred_at.iso8601(6),
            prior_gate_name: last.scanner_device&.name,
            offline_conflict: (true if input[:source] == "offline")
          }.compact
        }
      end

      if event.re_entry_exit_scan? && input[:source] == "offline"
        last_exit = day_actions.select(&:kind_exit?).last
        if last_exit && occurred_at < (last_exit.occurred_at - CLOCK_SKEW_TOLERANCE)
          return {
            result: :conflict,
            reason_code: "admit_before_latest_exit",
            flag_conflict: true,
            details: {
              last_exit_at: last_exit.occurred_at.iso8601(6),
              offline_conflict: true
            }.compact
          }
        end
      end

      prior_entries = day_actions.count(&:kind_admit?)
      if prior_entries.positive?
        cutoff_rejection = check_re_entry_cutoff(event, occurred_at, scan_day)
        return cutoff_rejection if cutoff_rejection

        cap_rejection = check_re_entry_cap(event, prior_entries - 1)
        return cap_rejection if cap_rejection

        return { result: :accepted, reason_code: "re_entered", details: { re_entry: true, re_entry_number: prior_entries, gate_name: device.name } }
      end

      { result: :accepted, reason_code: "admitted", details: { re_entry: false, re_entry_number: 0, gate_name: device.name } }
    end

    def evaluate_historical_day_exit(ticket, input, occurred_at, scan_day)
      day_actions = ticket.admission_actions.result_accepted.where(occupancy_day: scan_day).order(:occurred_at, :received_at, :id)
      last = day_actions.last
      unless last&.kind_admit? && (input[:source] == "online" || occurred_at >= (last.occurred_at - CLOCK_SKEW_TOLERANCE))
        return { result: :conflict, reason_code: "not_inside", details: { offline_conflict: (true if input[:source] == "offline") }.compact }
      end

      { result: :accepted, reason_code: "exited", details: { gate_name: device.name } }
    end

    def check_re_entry_cutoff(event, occurred_at, scan_day)
      cutoff = event.re_entry_cutoff_for_day(scan_day)
      return nil unless cutoff.present? && occurred_at > cutoff

      {
        result: :rejected,
        reason_code: "re_entry_cutoff_passed",
        details: {
          cutoff_at: cutoff.iso8601(6),
          cutoff_time: event.re_entry_cutoff_time
        }.compact
      }
    end

    def check_re_entry_cap(event, current_re_entries)
      return nil unless event.re_entry_max_count.present? && current_re_entries >= event.re_entry_max_count

      {
        result: :rejected,
        reason_code: "re_entry_limit_reached",
        details: { re_entry_count: current_re_entries, re_entry_max_count: event.re_entry_max_count }
      }
    end

    # Offline decisions use the signed list available at the door (including
    # v1 lists). Online decisions also enforce any stricter current settings.
    def verification_required?(ticket, entry, source)
      entry["door_check_mode"] == "verify" || (source == "online" && ticket.ticket_type.door_check_mode == "verify")
    end

    def reconcile_reversal(input)
      original = AdmissionAction.find_by(action_uuid: input[:reverses_action_uuid])
      original = nil unless original&.event_id == device.event_id && original.kind_admit? && original.result_accepted?
      unless OrganizationAuthorization.allowed?(
        user: actor,
        organization: device.organization,
        permission: :manage_attendees,
        event: device.event
      )
        return record_action(input, ticket: original&.ticket, result: :rejected,
          reason_code: "reversal_not_authorized", kind: :reverse, reverses_action: original)
      end

      unless original
        return record_action(input, result: :rejected, reason_code: "admission_not_found", kind: :reverse)
      end
      ticket = original.ticket
      ticket.order.lock!
      ticket.lock!
      validate_authorization!
      unless OrganizationAuthorization.allowed?(user: actor, organization: device.organization,
          permission: :manage_attendees, event: device.event)
        return record_action(input, ticket: ticket, result: :rejected,
          reason_code: "reversal_not_authorized", kind: :reverse, reverses_action: original)
      end
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

      ticket = device.event.tickets.includes(:ticket_type, :inventory_retention, :pending_refund_tickets, :last_entry_device,
        { parent_ticket: [:pending_refund_tickets, :inventory_retention] }, order: :disputes).find_by(id: entry["ticket_id"])
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

    def record_action(input, ticket: nil, result:, reason_code:, kind: :admit, entry: nil, reverses_action: nil, extra_metadata: {})
      occurred_at = input.fetch(:occurred_at)
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
        occurred_at: occurred_at,
        received_at: Time.current,
        occupancy_day: device.event.occupancy_day_for(occurred_at),
        attendee_snapshot: attendee_snapshot(ticket, entry),
        metadata: {
          client_status: input[:client_status],
          confirmed: (true if input[:confirmed]),
          reverses_action_uuid: kind == :reverse ? input[:reverses_action_uuid] : nil
        }.merge(extra_metadata || {}).compact
      )
      audit_action = case kind.to_sym
      when :reverse then "ticket.check_in_reversed"
      when :exit then "ticket.re_entry_exited"
      else "ticket.admission_reconciled"
      end
      AuditLogger.record!(
        action: audit_action,
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

    def validate_replay!(existing, input)
      unless existing.scanner_device_id == device.id && existing.event_id == device.event_id &&
          existing.sequence == input.fetch(:sequence) && existing.kind == input.fetch(:kind) &&
          existing.source == input.fetch(:source) && existing.credential_hash == input[:credential_hash] &&
          (existing.metadata["confirmed"] == true) == input[:confirmed] &&
          (existing.reverses_action&.action_uuid || existing.metadata["reverses_action_uuid"]) == input[:reverses_action_uuid]
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
