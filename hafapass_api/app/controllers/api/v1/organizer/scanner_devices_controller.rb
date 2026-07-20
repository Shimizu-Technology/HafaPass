# frozen_string_literal: true

class Api::V1::Organizer::ScannerDevicesController < Api::V1::Organizer::BaseController
  before_action :set_event
  before_action :set_device, only: [:update, :destroy, :manifest, :sync]

  def index
    return unless authorize_organization!(:scan, event: @event)

    devices = @event.scanner_devices.includes(:user).order(created_at: :desc)
    unless OrganizationAuthorization.allowed?(
      user: current_user, organization: current_organization, permission: :manage_staff, event: @event
    )
      devices = devices.where(user: current_user)
    end
    render json: devices.map { |device| device_json(device) }
  end

  def create
    device = Admissions::DeviceRegistrar.call(
      event: @event,
      user: current_user,
      identifier: params[:identifier],
      name: params[:name],
      request: request
    )
    render json: device_json(device), status: :created
  rescue Admissions::DeviceRegistrar::RegistrationError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def update
    return unless device_owner_or_manager?

    @device.update!(name: params[:name].presence || @device.name, last_seen_at: Time.current)
    render json: device_json(@device)
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  def destroy
    return unless authorize_organization!(:manage_staff, event: @event)

    @device.revoke!
    AuditLogger.record!(
      action: "scanner_device.revoked",
      auditable: @device,
      actor: current_user,
      organization: current_organization,
      metadata: { event_id: @event.id },
      request: request
    )
    head :no_content
  end

  def manifest
    return unless require_device_owner!
    return unless authorize_organization!(:scan, event: @event)
    return render_device_expired unless @device.effective?

    manifest = Admissions::ManifestBuilder.call(event: @event, actor: current_user)
    @device.update!(
      last_manifest_version: manifest.version,
      last_manifest_digest: manifest.digest,
      manifest_downloaded_at: Time.current,
      last_seen_at: Time.current
    )
    render json: manifest_json(manifest)
  rescue Admissions::ManifestBuilder::ManifestError, Admissions::ManifestSigner::ConfigurationError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def sync
    return unless require_device_owner!

    results = Admissions::Reconciler.call(
      device: @device,
      actor: current_user,
      actions: params[:actions]&.map { |action| action.respond_to?(:to_unsafe_h) ? action.to_unsafe_h : action },
      request: request
    )
    render json: {
      results: results.map { |result| action_json(result.action) },
      device: device_json(@device.reload),
      summary: admission_summary
    }
  rescue Admissions::Reconciler::SyncError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def set_event
    @event = find_organization_event(params[:event_id])
  end

  def set_device
    @device = @event&.scanner_devices&.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Scanner device not found" }, status: :not_found
  end

  def device_owner_or_manager?
    return true if @device.user_id == current_user.id

    authorize_organization!(:manage_staff, event: @event)
  end

  def require_device_owner!
    return true if @device.user_id == current_user.id || current_user.admin?

    render json: { error: "Scanner device belongs to another staff member" }, status: :forbidden
    false
  end

  def render_device_expired
    render json: { error: "Scanner device authorization has expired or was revoked" }, status: :forbidden
  end

  def device_json(device)
    {
      id: device.id,
      identifier: device.identifier,
      name: device.name,
      status: device.status,
      effective: device.effective?,
      authorization_expires_at: device.authorization_expires_at,
      last_manifest_version: device.last_manifest_version,
      last_manifest_digest: device.last_manifest_digest,
      manifest_downloaded_at: device.manifest_downloaded_at,
      last_synced_at: device.last_synced_at,
      last_seen_at: device.last_seen_at,
      last_sequence: device.last_sequence,
      user: { id: device.user_id, name: [device.user.first_name, device.user.last_name].compact.join(" ").presence }
    }
  end

  def manifest_json(manifest)
    {
      payload: manifest.payload,
      digest: manifest.digest,
      signature: manifest.signature,
      algorithm: manifest.algorithm,
      key_id: manifest.key_id,
      public_key_spki: Admissions::ManifestSigner.public_key_spki
    }
  end

  def action_json(action)
    {
      action_uuid: action.action_uuid,
      ticket_id: action.ticket_id,
      kind: action.kind,
      source: action.source,
      result: action.result,
      reason_code: action.reason_code,
      sequence: action.sequence,
      occurred_at: action.occurred_at,
      received_at: action.received_at,
      attendee: action.attendee_snapshot
    }
  end

  def admission_summary
    {
      admitted: @event.tickets.checked_in.count,
      remaining: @event.tickets.issued.count,
      conflicts: @event.admission_actions.result_conflict.count,
      rejected: @event.admission_actions.result_rejected.count
    }
  end
end
