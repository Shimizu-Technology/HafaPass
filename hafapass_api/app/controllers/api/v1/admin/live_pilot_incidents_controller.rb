# frozen_string_literal: true

class Api::V1::Admin::LivePilotIncidentsController < Api::V1::Admin::BaseController
  include LivePilotSerialization

  def create
    incident = LivePilotIncidents::Manager.report!(
      run: LivePilotRun.find(params[:id]), actor: current_user, attributes: incident_params, request: request
    )
    render json: live_pilot_incident_json(incident), status: :created
  rescue LivePilotIncidents::Manager::IncidentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def resolve
    incident = LivePilotIncidents::Manager.resolve!(
      incident: LivePilotIncident.find(params[:id]), actor: current_user,
      attributes: incident_params, request: request
    )
    render json: live_pilot_incident_json(incident), status: :created
  rescue LivePilotIncidents::Manager::IncidentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def incident_params
    params.permit(:severity, :category, :summary, :evidence_reference, :evidence_digest, :occurred_at)
  end
end
