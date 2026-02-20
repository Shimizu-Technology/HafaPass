# frozen_string_literal: true

class Api::V1::Admin::EventsController < Api::V1::Admin::BaseController
  # GET /api/v1/admin/events
  def index
    events = Event.includes(:organizer_profile, :ticket_types, :orders)

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
    params.permit(:is_featured, :status)
  end

  def event_json(e)
    tickets_sold = e.ticket_types.sum(&:quantity_sold)
    revenue = e.orders.select { |o| %w[completed partially_refunded].include?(o.status) }.sum(&:total_cents)
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
      revenue_cents: revenue,
      organizer_name: e.organizer_profile&.business_name,
      organizer_email: e.organizer_profile&.user&.email
    }
  end
end
