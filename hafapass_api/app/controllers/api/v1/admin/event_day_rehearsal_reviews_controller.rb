# frozen_string_literal: true

class Api::V1::Admin::EventDayRehearsalReviewsController < Api::V1::Admin::BaseController
  include EventDayRehearsalSerialization

  def show
    event = Event.find(params[:event_id])
    render json: { event: event_summary(event), event_day_rehearsal: event_day_rehearsal_json(event) }
  end

  def create
    review = EventDayRehearsalReviews::Manager.submit!(
      event: Event.find(params[:event_id]), attributes: review_params, actor: current_user, request: request
    )
    render json: event_day_rehearsal_review_json(review, active: false), status: :created
  rescue EventDayRehearsalReviews::Manager::ReviewError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def approve
    review = EventDayRehearsalReviews::Manager.approve!(
      submission: EventDayRehearsalReview.find(params[:id]), actor: current_user, request: request
    )
    active = EventDayRehearsal.active_approval(review.event)&.id == review.id
    render json: event_day_rehearsal_review_json(review, active: active), status: :created
  rescue EventDayRehearsalReviews::Manager::ReviewError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def reject
    review = EventDayRehearsalReviews::Manager.reject!(
      submission: EventDayRehearsalReview.find(params[:id]), actor: current_user,
      reason: params[:reason], request: request
    )
    render json: event_day_rehearsal_review_json(review, active: false), status: :created
  rescue EventDayRehearsalReviews::Manager::ReviewError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def revoke
    review = EventDayRehearsalReviews::Manager.revoke!(
      approval: EventDayRehearsalReview.find(params[:id]), actor: current_user,
      reason: params[:reason], request: request
    )
    render json: event_day_rehearsal_review_json(review, active: false), status: :created
  rescue EventDayRehearsalReviews::Manager::ReviewError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def review_params
    params.permit(
      :evidence_reference, :evidence_digest, :effective_at, :expires_at,
      manifest_results: EventDayRehearsalReview::MANIFEST_FIELDS,
      device_results: [EventDayRehearsalReview::DEVICE_FIELDS],
      scan_results: EventDayRehearsalReview::SCAN_KEYS,
      incident_drills: EventDayRehearsalReview::INCIDENT_KEYS.index_with {
        EventDayRehearsalReview::INCIDENT_FIELDS
      },
      door_sales_results: EventDayRehearsalReview::DOOR_CHANNELS.index_with {
        EventDayRehearsalReview::DOOR_SALE_FIELDS
      },
      reconciliation_results: EventDayRehearsalReview::RECONCILIATION_FIELDS,
      assignments: EventDayRehearsalReview::ASSIGNMENT_KEYS.index_with {
        EventDayRehearsalReview::ASSIGNMENT_FIELDS
      },
      controls: EventDayRehearsalReview::CONTROL_KEYS
    )
  end

  def event_summary(event)
    {
      id: event.id, title: event.title, status: event.status, starts_at: event.starts_at,
      venue_name: event.venue_name, max_capacity: event.max_capacity, assigned_seating: event.assigned_seating?
    }
  end
end
