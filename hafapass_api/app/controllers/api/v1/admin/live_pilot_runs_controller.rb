# frozen_string_literal: true

class Api::V1::Admin::LivePilotRunsController < Api::V1::Admin::BaseController
  include LivePilotSerialization

  def start
    run = LivePilotRuns::Manager.start!(
      approval: LivePilotReview.find(params[:id]), actor: current_user, request: request
    )
    render json: live_pilot_run_json(run), status: :created
  rescue LivePilotRuns::Manager::RunError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def pause
    transition(:pause, reason: params[:reason])
  end

  def resume
    transition(:resume, reason: params[:reason])
  end

  def abort
    transition(:abort, reason: params[:reason])
  end

  def complete
    permitted = params.permit(
      :completion_evidence_reference, :completion_evidence_digest,
      completion_results: LivePilotRuns::Manager::COMPLETION_BOOLEAN_FIELDS +
        LivePilotRuns::Manager::COMPLETION_ZERO_FIELDS
    )
    run = LivePilotRuns::Manager.complete!(
      run: run_record, actor: current_user,
      attributes: {
        completion_evidence_reference: permitted[:completion_evidence_reference],
        completion_evidence_digest: permitted[:completion_evidence_digest],
        completion_results: permitted[:completion_results]
      }, request: request
    )
    render json: live_pilot_run_json(run)
  rescue LivePilotRuns::Manager::RunError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def checkpoint
    permitted = params.permit(
      :evidence_reference, :evidence_digest, :observed_at,
      external_metrics: LivePilotMetrics::Manager::EXTERNAL_FIELDS
    )
    snapshot = LivePilotMetrics::Manager.record!(
      run: run_record, actor: current_user,
      attributes: {
        evidence_reference: permitted[:evidence_reference], evidence_digest: permitted[:evidence_digest],
        observed_at: permitted[:observed_at], external_metrics: permitted[:external_metrics]
      }, request: request
    )
    render json: live_pilot_metric_json(snapshot), status: :created
  rescue LivePilotMetrics::Manager::MetricError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def transition(action, reason:)
    run = case action
    when :pause
      LivePilotRuns::Manager.pause!(run: run_record, actor: current_user, reason: reason, request: request)
    when :resume
      LivePilotRuns::Manager.resume!(run: run_record, actor: current_user, reason: reason, request: request)
    when :abort
      LivePilotRuns::Manager.abort!(run: run_record, actor: current_user, reason: reason, request: request)
    end
    render json: live_pilot_run_json(run)
  rescue LivePilotRuns::Manager::RunError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def run_record
    LivePilotRun.find(params[:id])
  end
end
