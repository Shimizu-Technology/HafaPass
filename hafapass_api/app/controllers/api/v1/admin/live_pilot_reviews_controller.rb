# frozen_string_literal: true

class Api::V1::Admin::LivePilotReviewsController < Api::V1::Admin::BaseController
  include LivePilotSerialization

  def show
    event = Event.find(params[:event_id])
    render json: { event: event_summary(event), live_pilot: live_pilot_status_json(event) }
  end

  def create
    review = LivePilotReviews::Manager.submit!(
      event: Event.find(params[:event_id]), attributes: review_params, actor: current_user, request: request
    )
    render json: live_pilot_review_json(review, active: false), status: :created
  rescue LivePilotReviews::Manager::ReviewError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def approve
    decision(:approve)
  end

  def reject
    decision(:reject)
  end

  def revoke
    decision(:revoke)
  end

  private

  def decision(action)
    review = case action
    when :approve
      LivePilotReviews::Manager.approve!(submission: review_record, actor: current_user, request: request)
    when :reject
      LivePilotReviews::Manager.reject!(
        submission: review_record, actor: current_user, reason: params[:reason], request: request
      )
    when :revoke
      LivePilotReviews::Manager.revoke!(
        approval: review_record, actor: current_user, reason: params[:reason], request: request
      )
    end
    active = LivePilot.active_approval(review.event)&.id == review.id
    render json: live_pilot_review_json(review, active: active), status: :created
  rescue LivePilotReviews::Manager::ReviewError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def review_record
    LivePilotReview.find(params[:id])
  end

  def review_params
    params.permit(
      :evidence_reference, :evidence_digest, :inventory_cap, :effective_at, :expires_at,
      support_coverage: LivePilotReview::SUPPORT_WINDOWS.index_with { LivePilotReview::SUPPORT_FIELDS },
      assignments: LivePilotReview::ASSIGNMENT_KEYS.index_with { LivePilotReview::ASSIGNMENT_FIELDS },
      thresholds: LivePilotReview::THRESHOLD_FIELDS,
      controls: LivePilotReview::CONTROL_KEYS
    )
  end

  def event_summary(event)
    {
      id: event.id, title: event.title, status: event.status, starts_at: event.starts_at, ends_at: event.ends_at,
      venue_name: event.venue_name, max_capacity: event.max_capacity
    }
  end
end
