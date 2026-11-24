# frozen_string_literal: true

class Api::V1::Organizer::AdmissionsController < Api::V1::Organizer::BaseController
  before_action :set_event
  before_action :require_admission_access

  def show
    render json: admission_dashboard
  end

  def search
    query = params[:q].to_s.strip
    return render json: [] if query.length < 2

    escaped = ActiveRecord::Base.sanitize_sql_like(query)
    tickets = @event.tickets.scannable.preload(:ticket_type, :order, :inventory_retention, :pending_refund_tickets, :last_entry_device,
      parent_ticket: :pending_refund_tickets)
      .where("tickets.attendee_name ILIKE :query OR CAST(tickets.id AS TEXT) = :exact",
        query: "%#{escaped}%", exact: query.delete_prefix("HP-T"))
      .order(:attendee_name, :id).limit(20)
    render json: tickets.map { |ticket| ticket_json(ticket) }
  end

  def override
    device = nil
    if params[:scanner_device_id].present?
      device = @event.scanner_devices.find_by(id: params[:scanner_device_id], user_id: current_user.id)
      unless device
        return render json: { error: "Scanner device not found for this staff member" }, status: :unprocessable_entity
      end
    end
    result = Admissions::LeadOverride.call(
      event: @event,
      actor: current_user,
      ticket_id: params[:ticket_id],
      override_action: params[:override_action],
      reason: params[:reason],
      action_uuid: params[:action_uuid],
      device: device,
      request: request
    )
    render json: {
      action: action_summary(result.action),
      ticket: ticket_json(result.ticket.reload),
      summary: Admissions::Counts.call(event: @event)
    }
  rescue Admissions::LeadOverride::ForbiddenError => e
    render json: { error: e.message }, status: :forbidden
  rescue Admissions::LeadOverride::OverrideError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def door_list
    return unless authorize_organization!(:manage_attendees, event: @event)

    ticket_count = @event.tickets.scannable.count
    if ticket_count > Admissions::DoorListPdf::MAX_TICKETS
      return render json: { error: "Emergency door list is limited to #{Admissions::DoorListPdf::MAX_TICKETS} tickets. Use a filtered organizer door list or contact support." }, status: :unprocessable_entity
    end

    pdf = Admissions::DoorListPdf.new(@event).generate
    AuditLogger.record!(action: "sales.emergency_door_list_exported", auditable: @event, actor: current_user,
      organization: current_organization,
      metadata: { filters: {}, columns: %w[ticket attendee type status door_mark], row_count: ticket_count },
      request: request)
    response.headers["Cache-Control"] = "no-store"
    send_data pdf,
      filename: "hafapass-door-list-#{@event.slug}.pdf",
      type: "application/pdf",
      disposition: "attachment"
  end

  private

  def set_event
    @event = find_organization_event(params[:event_id])
  end

  def require_admission_access
    authorize_organization!(:scan, event: @event) if @event
  end

  def admission_dashboard
    actions = @event.admission_actions.includes(:scanner_device, :actor_user, :reversal_action).order(received_at: :desc).limit(50)
    flagged = @event.tickets.scannable.where(re_entry_conflict_flagged: true)
      .preload(:ticket_type, :order, :inventory_retention, :pending_refund_tickets, :last_entry_device, parent_ticket: :pending_refund_tickets)
      .order(updated_at: :desc).limit(50)
    {
      event: {
        id: @event.id,
        title: @event.title,
        status: @event.status,
        venue_name: @event.venue_name,
        starts_at: @event.starts_at,
        ends_at: @event.ends_at,
        timezone: @event.timezone,
        re_entry_mode: @event.re_entry_mode,
        re_entry_max_count: @event.re_entry_max_count,
        re_entry_cutoff_at: @event.re_entry_cutoff_at,
        re_entry_cutoff_time: @event.re_entry_cutoff_time,
        re_entry_cooldown_minutes: @event.re_entry_cooldown_minutes,
        re_entry_rollover_hour: @event.re_entry_rollover_hour
      },
      counts: Admissions::Counts.call(event: @event),
      devices: @event.scanner_devices.includes(:user).order(last_seen_at: :desc).map { |device| device_summary(device) },
      recent_actions: actions.map { |action| action_summary(action) },
      flagged_conflicts: flagged.map { |ticket| ticket_json(ticket) },
      latest_manifest: manifest_summary(@event.admission_manifests.order(version: :desc).first),
      permissions: {
        can_recover: OrganizationAuthorization.allowed?(user: current_user, organization: current_organization,
          permission: :manage_staff, event: @event) && OrganizationAuthorization.allowed?(user: current_user,
          organization: current_organization, permission: :manage_attendees, event: @event),
        can_reverse: OrganizationAuthorization.allowed?(user: current_user, organization: current_organization,
          permission: :manage_attendees, event: @event),
        can_override: @event.re_entry_enabled? && OrganizationAuthorization.allowed?(user: current_user,
          organization: current_organization, permission: :override_re_entry, event: @event)
      }
    }
  end

  def ticket_json(ticket)
    {
      id: ticket.id,
      code: "HP-T#{ticket.id}",
      attendee_name: ticket.attendee_name,
      ticket_type: [ticket.ticket_type.name, ticket.seat_label].compact.join(" · "),
      seat: ticket.seat_label,
      status: ticket.status,
      checked_in_at: ticket.checked_in_at,
      admission_allowed: ticket.admission_allowed?,
      occupancy_state: ticket.occupancy_state,
      occupancy_day: ticket.occupancy_day&.iso8601,
      last_entry_at: ticket.last_entry_at,
      last_entry_gate: ticket.last_entry_device&.name,
      last_exit_at: ticket.last_exit_at,
      re_entry_count: ticket.re_entry_count,
      re_entry_conflict_flagged: ticket.re_entry_conflict_flagged
    }
  end

  def device_summary(device)
    {
      id: device.id,
      name: device.name,
      status: device.status,
      effective: device.effective?,
      staff_name: [device.user.first_name, device.user.last_name].compact.join(" ").presence,
      last_seen_at: device.last_seen_at,
      last_synced_at: device.last_synced_at,
      last_manifest_version: device.last_manifest_version
    }
  end

  def action_summary(action)
    {
      action_uuid: action.action_uuid,
      ticket_id: action.ticket_id,
      kind: action.kind,
      result: action.result,
      reversed: action.kind_admit? && action.reversal_action.present?,
      reason_code: action.reason_code,
      occurred_at: action.occurred_at,
      received_at: action.received_at,
      occupancy_day: action.occupancy_day&.iso8601,
      attendee: action.attendee_snapshot,
      device_name: action.scanner_device&.name || action.metadata["gate_name"],
      details: action.metadata.slice(
        "prior_entry_at", "prior_gate_name", "elapsed_minutes", "remaining_minutes",
        "cooldown_minutes", "retry_after_at", "re_entry", "re_entry_number",
        "re_entry_count", "re_entry_max_count", "cutoff_at", "cutoff_time", "offline_conflict",
        "winner_by_occurred_at", "override_action"
      )
    }
  end

  def manifest_summary(manifest)
    return unless manifest

    {
      version: manifest.version,
      digest: manifest.digest,
      ticket_count: manifest.ticket_count,
      generated_at: manifest.generated_at,
      expires_at: manifest.expires_at
    }
  end
end
