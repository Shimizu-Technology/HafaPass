# frozen_string_literal: true

class Api::V1::Admin::EventsController < Api::V1::Admin::BaseController
  # GET /api/v1/admin/events
  def index
    events = Event.includes(:organizer_profile, :ticket_types, :orders, :pilot_readiness_reviews,
      :pilot_validation_reviews, :event_day_rehearsal_reviews, :live_pilot_reviews, :live_pilot_runs,
      :pilot_closeout_reviews,
      organization: :live_money_proof_reviews)

    events = events.where("title ILIKE ?", "%#{params[:search]}%") if params[:search].present?
    events = events.where(status: params[:status]) if params[:status].present?
    events = events.where(category: params[:category]) if params[:category].present?

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

  private

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
      pilot_closeout: PilotCloseout.list_summary(e)
    }
  end
end
