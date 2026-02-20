# frozen_string_literal: true

class Api::V1::Admin::DashboardController < Api::V1::Admin::BaseController
  # GET /api/v1/admin/dashboard
  def show
    render json: {
      total_events: Event.group(:status).count,
      total_users: User.group(:role).count,
      total_orders: Order.count,
      total_revenue_cents: Order.where(status: [:completed, :partially_refunded]).sum(:total_cents),
      total_tickets_sold: Ticket.where(status: [:issued, :checked_in]).count,
      recent_events: recent_events_json,
      recent_orders: recent_orders_json
    }
  end

  private

  def recent_events_json
    Event.includes(:organizer_profile).order(created_at: :desc).limit(5).map do |e|
      {
        id: e.id,
        title: e.title,
        slug: e.slug,
        status: e.status,
        category: e.category,
        starts_at: e.starts_at,
        created_at: e.created_at,
        organizer_name: e.organizer_profile&.business_name
      }
    end
  end

  def recent_orders_json
    Order.includes(:event, :user).order(created_at: :desc).limit(10).map do |o|
      {
        id: o.id,
        buyer_name: o.buyer_name,
        buyer_email: o.buyer_email,
        total_cents: o.total_cents,
        status: o.status,
        event_title: o.event&.title,
        event_slug: o.event&.slug,
        created_at: o.created_at
      }
    end
  end
end
