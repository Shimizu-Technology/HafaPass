# frozen_string_literal: true

class Api::V1::Admin::EventPolicyHoldsController < Api::V1::Admin::BaseController
  before_action :set_event

  # POST /api/v1/admin/events/:event_id/policy_hold
  def create
    EventPolicyHold.place!(event: @event, actor: current_user, scope: params[:scope], reason: params[:reason],
      request: request)
    render json: policy_hold_json(@event.reload), status: :created
  rescue EventPolicyHold::HoldError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # DELETE /api/v1/admin/events/:event_id/policy_hold
  def destroy
    EventPolicyHold.lift!(event: @event, actor: current_user, reason: params[:reason], request: request)
    render json: policy_hold_json(@event.reload)
  rescue EventPolicyHold::HoldError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def set_event
    @event = Event.find(params[:event_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Event not found" }, status: :not_found
  end

  def policy_hold_json(event)
    { id: event.id, status: event.status, policy_hold: event.policy_hold_summary(include_actor: true) }
  end
end
