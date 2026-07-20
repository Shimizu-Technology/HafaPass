class Api::V1::Me::OrdersController < ApplicationController
  include Paginatable

  def index
    orders = current_user.orders
      .includes(:payments, :refunds, :disputes, :order_items, :promo_code,
        event: { event_changes: :event_change_responses }, tickets: [:ticket_type, :order_item])
      .order(created_at: :desc)

    pagy, paginated_orders = paginate(orders)

    render json: {
      orders: paginated_orders.map { |order| OrderPresenter.call(order, include_tickets: true) },
      meta: pagination_meta(pagy)
    }
  end

  def show
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
