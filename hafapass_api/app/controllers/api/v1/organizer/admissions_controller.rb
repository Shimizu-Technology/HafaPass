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
    tickets = @event.tickets.includes(:ticket_type, :order)
      .where("tickets.attendee_name ILIKE :query OR CAST(tickets.id AS TEXT) = :exact",
        query: "%#{escaped}%", exact: query.delete_prefix("HP-T"))
      .order(:attendee_name, :id).limit(20)
    render json: tickets.map { |ticket| ticket_json(ticket) }
  end

  def door_list
    return unless authorize_organization!(:manage_attendees, event: @event)

    send_data Admissions::DoorListPdf.new(@event).generate,
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
    ticket_counts = @event.tickets.group(:status).count
    actions = @event.admission_actions.includes(:scanner_device, :actor_user).order(received_at: :desc).limit(50)
    {
      event: {
        id: @event.id,
        title: @event.title,
        status: @event.status,
        venue_name: @event.venue_name,
        starts_at: @event.starts_at,
        ends_at: @event.ends_at,
        timezone: @event.timezone
      },
      counts: {
        total: ticket_counts.values.sum,
        admitted: ticket_counts.fetch("checked_in", 0),
        remaining: ticket_counts.fetch("issued", 0),
        cancelled: ticket_counts.fetch("cancelled", 0),
        conflicts: @event.admission_actions.result_conflict.count,
        rejected: @event.admission_actions.result_rejected.count
      },
      devices: @event.scanner_devices.includes(:user).order(last_seen_at: :desc).map { |device| device_summary(device) },
      recent_actions: actions.map { |action| action_summary(action) },
      latest_manifest: manifest_summary(@event.admission_manifests.order(version: :desc).first),
      permissions: {
        can_reverse: OrganizationAuthorization.allowed?(user: current_user, organization: current_organization,
          permission: :manage_attendees, event: @event)
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
      admission_allowed: ticket.admission_allowed?
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
      reason_code: action.reason_code,
      occurred_at: action.occurred_at,
      received_at: action.received_at,
      attendee: action.attendee_snapshot,
      device_name: action.scanner_device&.name
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
