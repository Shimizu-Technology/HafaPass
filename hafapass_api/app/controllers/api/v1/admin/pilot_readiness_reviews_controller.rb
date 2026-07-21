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
    controls = params[:controls].respond_to?(:permit) ?
      params.require(:controls).permit(*PilotReadinessReview::CONTROL_KEYS).to_h : {}
    assignments = params[:assignments].respond_to?(:permit) ?
      params.require(:assignments).permit(
        PilotReadinessReview::ASSIGNMENT_KEYS.index_with { PilotReadinessReview::ASSIGNMENT_FIELDS }
      ).to_h : {}
    permitted.to_h.merge(controls: controls, assignments: assignments)
  rescue ArgumentError
    {}
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
