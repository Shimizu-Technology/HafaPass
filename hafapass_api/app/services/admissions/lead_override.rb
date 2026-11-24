# frozen_string_literal: true

module Admissions
  # Audited scanner-lead override to admit a guest past an anti-passback,
  # cooldown, cap or cutoff block, or to clear a stuck inside/conflict state.
  # Follows docs/LOCKING.md rank order: actor -> org -> event -> device ->
  # memberships -> assignments -> order -> ticket.
  class LeadOverride
    class OverrideError < StandardError; end
    class ForbiddenError < OverrideError; end

    OVERRIDE_ACTIONS = %w[admit clear].freeze

    def self.call(**)
      AuditContext.set(fail_open: false) { new(**).call }
    end

    def initialize(event:, actor:, ticket_id:, override_action:, reason:, action_uuid: nil, device: nil, request: nil)
      @event = event
      @actor = actor
      @ticket_id = Integer(ticket_id, exception: false)
      @override_action = override_action.to_s
      @reason = reason.to_s.strip
      @action_uuid = action_uuid.to_s.strip.presence || SecureRandom.uuid
      @device = device
      @request = request
    end

    def call
      validate_inputs!

      AdmissionAction.transaction do
        lock_context!
        validate_authority!

        existing = AdmissionAction.find_by(action_uuid: @action_uuid)
        return validate_replay!(existing) if existing

        ticket = @event.tickets.includes(:ticket_type, :inventory_retention, :pending_refund_tickets,
          { parent_ticket: [:pending_refund_tickets, :inventory_retention] }, order: :disputes)
          .find_by(id: @ticket_id)
        raise OverrideError, "Ticket not found for this event" unless ticket

        ticket.order.lock!
        ticket.lock!
        validate_authority!

        block = ticket.admission_block_reason(allow_checked_in: true)
        raise OverrideError, "Ticket cannot be overridden while #{block.tr('_', ' ')}" if block

        at = Time.current
        scan_day = @event.occupancy_day_for(at)
        prior_state = ticket.effective_occupancy_state(day: scan_day)

        reason_code = if @override_action == "admit"
          if !ticket.checked_in?
            ticket.check_in!(occurred_at: at, device: @device)
          else
            ticket.record_re_entry!(occurred_at: at, device: @device, day: scan_day, clear_conflict: true)
          end
          "lead_override_admitted"
        else
          ticket.record_exit!(occurred_at: at, day: scan_day, clear_conflict: true)
          "lead_override_cleared"
        end

        action = AdmissionAction.create!(
          organization: @event.organization,
          event: @event,
          ticket: ticket,
          scanner_device: nil,
          actor_user: @actor,
          action_uuid: @action_uuid,
          kind: :override,
          source: :manual,
          result: :accepted,
          reason_code: reason_code,
          occurred_at: at,
          received_at: at,
          occupancy_day: scan_day,
          attendee_snapshot: {
            code: "HP-T#{ticket.id}",
            attendee_name: ticket.attendee_name,
            ticket_type: ticket.ticket_type&.name
          }.compact,
          metadata: {
            override_action: @override_action,
            reason: @reason,
            prior_occupancy_state: prior_state,
            gate_name: @device&.name,
            scanner_device_id: @device&.id
          }.compact
        )

        AuditLogger.record!(
          action: "ticket.re_entry_overridden",
          auditable: action,
          actor: @actor,
          organization: @event.organization,
          event: @event,
          after_data: { result: action.result, reason_code: action.reason_code, ticket_id: ticket.id },
          metadata: { event_id: @event.id, override_action: @override_action, reason: @reason },
          request: @request
        )

        Reconciler::Result.new(action: action, ticket: ticket)
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      raise OverrideError, e.message
    end

    private

    def validate_inputs!
      raise OverrideError, "A valid ticket_id is required" unless @ticket_id&.positive?
      unless OVERRIDE_ACTIONS.include?(@override_action)
        raise OverrideError, "override_action must be one of: #{OVERRIDE_ACTIONS.join(', ')}"
      end
      unless @reason.length.between?(3, 500)
        raise OverrideError, "Provide a reason for the override (3–500 characters)"
      end
      raise OverrideError, "action_uuid is too long" if @action_uuid.length > 128
      if @device && @device.event_id != @event.id
        raise OverrideError, "Scanner device does not belong to this event"
      end
    end

    def lock_context!
      @actor.lock!("FOR NO KEY UPDATE")
      @event.organization.lock!("FOR NO KEY UPDATE")
      @event.lock!
      @device&.lock!
      @event.organization.organization_memberships.where(user_id: @actor.id).order(:id).lock.load
      @event.event_staff_assignments.where(user_id: @actor.id).order(:id).lock.load
    end

    def validate_authority!
      unless OrganizationAuthorization.allowed?(
        user: @actor,
        organization: @event.organization,
        permission: :override_re_entry,
        event: @event
      )
        raise ForbiddenError, "Scanner lead or event manager permission is required for overrides"
      end
    end

    def validate_replay!(existing)
      unless existing.event_id == @event.id && existing.kind_override? &&
          existing.ticket_id == @ticket_id && existing.metadata["override_action"] == @override_action
        raise OverrideError, "action_uuid was already used for a different override"
      end

      Reconciler::Result.new(action: existing, ticket: existing.ticket)
    end
  end
end
