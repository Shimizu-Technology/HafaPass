# frozen_string_literal: true

class Api::V1::Admin::PilotCloseoutReviewsController < Api::V1::Admin::BaseController
  include PilotCloseoutSerialization

  def show
    event = Event.find(params[:event_id])
    render json: {
      event: { id: event.id, title: event.title, status: event.status, starts_at: event.starts_at,
        ends_at: event.ends_at },
      pilot_closeout: pilot_closeout_status_json(event)
    }
  end

  def create
    event = Event.find(params[:event_id])
    run = event.live_pilot_runs.status_completed.order(completed_at: :desc).first
    raise PilotCloseoutReviews::Manager::ReviewError, "Complete Gate I before starting Gate J" unless run

    review = PilotCloseoutReviews::Manager.submit!(
      run: run, attributes: closeout_params, actor: current_user, request: request
    )
    render json: pilot_closeout_review_json(review, active: false), status: :created
  rescue PilotCloseoutReviews::Manager::ReviewError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def approve
    review = PilotCloseoutReviews::Manager.approve!(
      submission: PilotCloseoutReview.find(params[:id]), actor: current_user, request: request
    )
    render json: pilot_closeout_review_json(review, active: true), status: :created
  rescue PilotCloseoutReviews::Manager::ReviewError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def reject
    negative_decision(:reject)
  end

  def revoke
    negative_decision(:revoke)
  end

  private

  def negative_decision(action)
    record = PilotCloseoutReview.find(params[:id])
    review = if action == :reject
      PilotCloseoutReviews::Manager.reject!(
        submission: record, actor: current_user, reason: params[:reason], request: request
      )
    else
      PilotCloseoutReviews::Manager.revoke!(
        approval: record, actor: current_user, reason: params[:reason], request: request
      )
    end
    render json: pilot_closeout_review_json(review, active: false), status: :created
  rescue PilotCloseoutReviews::Manager::ReviewError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def closeout_params
    params.permit(
      :evidence_reference, :evidence_digest, :expansion_decision,
      outcome_metrics: PilotCloseoutReview::OUTCOME_INTEGER_FIELDS,
      reconciliation_results: PilotCloseoutReview::RECONCILIATION_FIELDS,
      cleanup_results: PilotCloseoutReview::CLEANUP_FIELDS,
      evidence_references: PilotCloseoutReview::EVIDENCE_REFERENCE_FIELDS,
      retrospective_actions: [
        :title, :owner_reference, :due_at, :status, :priority, :evidence_reference, :blocks_expansion
      ],
      expansion_scope: [
        :event_limit, :max_inventory_per_event, :expires_at, :new_regions, :product_evidence_reference,
        :demand_evidence_reference, :capacity_evidence_reference, :rationale,
        { recommended_product_investments: [] }
      ]
    )
  end
end
