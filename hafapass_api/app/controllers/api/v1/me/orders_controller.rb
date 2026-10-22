class Api::V1::Me::OrdersController < ApplicationController
  include Paginatable

  def recover_guest
    render json: GuestPurchaseRecovery.call(user: current_user, request: request)
  end

  def index
    response.headers["Cache-Control"] = "private, no-store"
    orders = current_user.orders.where(status: [:completed, :partially_refunded, :refunded, :cancelled])
      .where("orders.completed_at IS NOT NULL OR EXISTS (SELECT 1 FROM payments WHERE payments.order_id = orders.id AND payments.status IN (?))",
        [Payment.statuses.fetch("succeeded"), Payment.statuses.fetch("partially_refunded"), Payment.statuses.fetch("refunded")])
      .includes(:payments, :refunds, :disputes, :order_items, :event)
      .order(created_at: :desc, id: :desc)

    pagy, paginated_orders = paginate(orders)

    render json: {
      orders: paginated_orders.map { |order| OrderCardPresenter.call(order) },
      meta: pagination_meta(pagy)
    }
  end

  def show
    response.headers["Cache-Control"] = "private, no-store"
    order = current_user.orders
      .includes(:payments, :refunds, :disputes, :order_items, :promo_code,
        event: { event_changes: :event_change_responses }, tickets: [:ticket_type, :order_item])
      .find_by(id: params[:id])

    unless order
      render json: { error: "Order not found" }, status: :not_found
      return
    end

    render json: OrderPresenter.call(order, include_tickets: true)
  end
end
