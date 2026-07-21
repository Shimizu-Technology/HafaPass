# frozen_string_literal: true

class Api::V1::Admin::PilotValidationReviewsController < Api::V1::Admin::BaseController
  include PilotValidationSerialization

  def show
    event = Event.find(params[:event_id])
    render json: { event: event_summary(event), pilot_validation: pilot_validation_json(event) }
  end

  def create
    review = PilotValidationReviews::Manager.submit!(
      event: Event.find(params[:event_id]), attributes: review_params, actor: current_user, request: request
    )
    render json: pilot_validation_review_json(review), status: :created
  rescue PilotValidationReviews::Manager::ReviewError => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue ActionController::BadRequest => e
    render json: { error: e.message }, status: :bad_request
  end

  def approve
    review = PilotValidationReviews::Manager.approve!(
      submission: PilotValidationReview.find(params[:id]), actor: current_user, request: request
    )
    render json: pilot_validation_review_json(review), status: :created
  rescue PilotValidationReviews::Manager::ReviewError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def reject
    review = PilotValidationReviews::Manager.reject!(
      submission: PilotValidationReview.find(params[:id]), actor: current_user, reason: params[:reason], request: request
    )
    render json: pilot_validation_review_json(review), status: :created
  rescue PilotValidationReviews::Manager::ReviewError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def revoke
    review = PilotValidationReviews::Manager.revoke!(
      approval: PilotValidationReview.find(params[:id]), actor: current_user, reason: params[:reason], request: request
    )
    render json: pilot_validation_review_json(review), status: :created
  rescue PilotValidationReviews::Manager::ReviewError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def review_params
    permitted = params.permit(:evidence_reference, :evidence_digest, :effective_at, :expires_at)
    device_shape = PilotValidationReview::DEVICE_TARGETS.keys.index_with { PilotValidationReview::DEVICE_FIELDS }
    assistive_shape = PilotValidationReview::ASSISTIVE_TECHNOLOGY_TARGETS.index_with do
      PilotValidationReview::ASSISTIVE_TECHNOLOGY_FIELDS
    end
    accessibility_shape = {
      checks: PilotValidationReview::ACCESSIBILITY_CHECK_KEYS,
      assistive_technology: assistive_shape,
      reviewer: PilotValidationReview::ACCESSIBILITY_REVIEWER_FIELDS
    }
    permitted.to_h.merge(
      device_matrix: nested_hash(:device_matrix, device_shape),
      buyer_flows: nested_hash(:buyer_flows, PilotValidationReview::BUYER_FLOW_KEYS),
      organizer_flows: nested_hash(:organizer_flows, PilotValidationReview::ORGANIZER_FLOW_KEYS),
      accessibility_results: nested_hash(:accessibility_results, accessibility_shape),
      load_results: nested_hash(:load_results, PilotValidationReview::LOAD_RESULT_FIELDS),
      controls: nested_hash(:controls, PilotValidationReview::CONTROL_KEYS)
    )
  end

  def nested_hash(key, permitted_shape)
    value = params[key]
    return {} if value.nil? || value == {}
    raise ActionController::BadRequest, "#{key} must be an object" unless value.respond_to?(:permit)

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
