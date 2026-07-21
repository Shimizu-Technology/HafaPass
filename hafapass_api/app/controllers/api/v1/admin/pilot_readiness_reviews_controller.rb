# frozen_string_literal: true

class Api::V1::Admin::PilotReadinessReviewsController < Api::V1::Admin::BaseController
  include PilotReadinessSerialization

  def show
    event = Event.find(params[:event_id])
    render json: { event: event_summary(event), pilot_readiness: pilot_readiness_json(event) }
  end

  def create
    review = PilotReadinessReviews::Manager.submit!(
      event: Event.find(params[:event_id]), attributes: review_params, actor: current_user, request: request
    )
    render json: pilot_readiness_review_json(review), status: :created
  rescue PilotReadinessReviews::Manager::ReviewError => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue ActionController::BadRequest => e
    render json: { error: e.message }, status: :bad_request
  end

  def approve
    review = PilotReadinessReviews::Manager.approve!(
      submission: PilotReadinessReview.find(params[:id]), actor: current_user, request: request
    )
    render json: pilot_readiness_review_json(review), status: :created
  rescue PilotReadinessReviews::Manager::ReviewError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def reject
    review = PilotReadinessReviews::Manager.reject!(
      submission: PilotReadinessReview.find(params[:id]), actor: current_user, reason: params[:reason], request: request
    )
    render json: pilot_readiness_review_json(review), status: :created
  rescue PilotReadinessReviews::Manager::ReviewError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def revoke
    review = PilotReadinessReviews::Manager.revoke!(
      approval: PilotReadinessReview.find(params[:id]), actor: current_user, reason: params[:reason], request: request
    )
    render json: pilot_readiness_review_json(review), status: :created
  rescue PilotReadinessReviews::Manager::ReviewError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def review_params
    permitted = params.permit(:evidence_reference, :evidence_digest, :effective_at, :expires_at)
    controls = nested_hash(:controls, PilotReadinessReview::CONTROL_KEYS)
    assignment_shape = PilotReadinessReview::ASSIGNMENT_KEYS.index_with { PilotReadinessReview::ASSIGNMENT_FIELDS }
    assignments = nested_hash(:assignments, assignment_shape)
    permitted.to_h.merge(controls: controls, assignments: assignments)
  end

  def nested_hash(key, permitted_shape)
    value = params[key]
    return {} if value.nil? || value == {}
    unless value.respond_to?(:permit)
      raise ActionController::BadRequest, "#{key} must be an object"
    end

    permitted_shape.is_a?(Hash) ? value.permit(permitted_shape).to_h : value.permit(*permitted_shape).to_h
  end

  def event_summary(event)
    {
      id: event.id,
      title: event.title,
      status: event.status,
      starts_at: event.starts_at,
      venue_name: event.venue_name,
      max_capacity: event.max_capacity,
      assigned_seating: event.assigned_seating?
    }
  end
end
