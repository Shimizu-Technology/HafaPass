# frozen_string_literal: true

class Api::V1::Admin::EventsController < Api::V1::Admin::BaseController
  include CancellationRefundActions
  before_action :set_cancellation_event, only: [:cancellation_refunds, :cancel_and_refund,
    :start_cancellation_refunds, :retry_cancellation_refunds, :mark_cash_refunded]

  def cancel_and_refund
    preview = EventCancellationRefunds.preview(@event)
    if !params.key?(:refund_count) || !params.key?(:refund_total_cents) ||
        params[:refund_count].to_i != preview[:count] || params[:refund_total_cents].to_i != preview[:total_cents]
      return render json: { error: "Refund total changed. Review the current count and amount before cancelling.",
        preview: preview }, status: :conflict
    end
    EventLifecycle.call(event: @event, action: :cancel, actor: @current_user, reason: params[:reason],
      expected_refund_count: params[:refund_count].to_i, expected_refund_total_cents: params[:refund_total_cents].to_i)
    render json: cancellation_json, status: :accepted
  rescue EventLifecycle::TransitionError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def start_cancellation_refunds
    run = nil
    @event.organization.with_lock do
      @event.with_lock do
        unless @event.cancelled? && @event.event_cancellation_refund_run.nil?
          return render json: { error: "Only a cancelled event without a refund run can be started" }, status: :conflict
        end
        preview = EventCancellationRefunds.preview(@event)
        if !params.key?(:refund_count) || !params.key?(:refund_total_cents) ||
            params[:refund_count].to_i != preview[:count] || params[:refund_total_cents].to_i != preview[:total_cents]
          return render json: { error: "Refund total changed. Review the current count and amount before starting.",
            preview: preview }, status: :conflict
        end

        run = EventCancellationRefunds.prepare!(event: @event, actor: current_user)
        AuditLogger.record!(action: "event.legacy_cancellation_refunds_started", auditable: @event,
          actor: current_user, organization: @event.organization,
          metadata: { run_id: run.id }, request: request)
      end
    end
    EventCancellationRefundJob.perform_later(run.id)
    render json: cancellation_json, status: :accepted
  end
  # GET /api/v1/admin/events
  def index
    events = Event.includes(:organizer_profile, :policy_hold_by_user, :ticket_types, :orders, :pilot_readiness_reviews,
      :pilot_validation_reviews, :event_day_rehearsal_reviews, :live_pilot_reviews, :live_pilot_runs,
      :pilot_closeout_reviews,
      organization: :live_money_proof_reviews)

    events = events.accent_insensitive_search(params[:search], :title) if params[:search].present?
    events = events.where(status: params[:status]) if params[:status].present?
    events = events.where(category: params[:category]) if params[:category].present?
    events = events.where.not(policy_hold_at: nil) if params[:policy_hold] == "true"

    events = events.order(created_at: :desc)

    page = (params[:page] || 1).to_i
    per_page = (params[:per_page] || 20).to_i
    total = events.count
    events = events.offset((page - 1) * per_page).limit(per_page)

    render json: {
      events: events.map { |e| event_json(e) },
      meta: { page: page, per_page: per_page, total: total, total_pages: (total.to_f / per_page).ceil }
    }
  end

  # PATCH /api/v1/admin/events/:id
  def update
    event = Event.find(params[:id])
    if event.update(event_params)
      render json: event_json(event)
    else
      render json: { errors: event.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # POST /api/v1/admin/events/:id/retranslate
  def retranslate
    event = Event.find(params[:id])
    outcome = Event.retranslate_with_ticket_types(event)
    unless outcome == :queued
      message, status = Event::RETRANSLATE_REFUSALS.fetch(outcome)
      return render json: { error: message, code: outcome.to_s }, status: status
    end

    render json: { translation_status: event.reload.translation_status }, status: :accepted
  end

  private

  def set_cancellation_event
    @event = Event.find(params[:id])
  end

  def event_params
    params.permit(:is_featured, :live_money_proof_candidate)
  end

  def event_json(e)
    tickets_sold = e.ticket_types.loaded? ? e.ticket_types.sum(&:quantity_sold) : e.ticket_types.sum(:quantity_sold)
    financials = Commerce::LedgerTotals.call(e.orders.where(status: [:completed, :partially_refunded, :refunded]))
    {
      id: e.id,
      title: e.title,
      slug: e.slug,
      status: e.status,
      translation_status: e.translation_status,
      category: e.category,
      is_featured: e.is_featured,
      starts_at: e.starts_at,
      created_at: e.created_at,
      tickets_sold: tickets_sold,
      revenue_cents: financials[:net_cents],
      financials: financials,
      organizer_name: e.organizer_profile&.business_name,
      organizer_email: e.organizer_profile&.user&.email,
      pilot_readiness: PilotReadiness.list_summary(e),
      pilot_validation: PilotValidation.list_summary(e),
      event_day_rehearsal: EventDayRehearsal.list_summary(e),
      live_money_proof_candidate: e.live_money_proof_candidate,
      live_money_proof: LiveMoneyProof.list_summary(e.organization),
      live_pilot: LivePilot.list_summary(e),
      pilot_closeout: PilotCloseout.list_summary(e),
      organization_id: e.organization_id,
      sales_suspended: e.sales_suspended_at.present?,
      sales_suspension_reason: e.sales_suspension_reason,
      policy_hold: e.policy_hold_summary(include_actor: true)
    }
  end
end
