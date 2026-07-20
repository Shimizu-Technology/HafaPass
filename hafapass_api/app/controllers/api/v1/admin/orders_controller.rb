# frozen_string_literal: true

class Api::V1::Admin::OrdersController < Api::V1::Admin::BaseController
  # GET /api/v1/admin/orders
  def index
    orders = Order.includes(
      :event, :user, :order_items, :payments, :refunds, :reconciliation_exceptions,
      tickets: :ticket_type
    )

    if params[:search].present?
      q = "%#{params[:search]}%"
      orders = orders.where("buyer_name ILIKE :q OR buyer_email ILIKE :q", q: q)
    end
    orders = orders.where(status: params[:status]) if params[:status].present?
    orders = orders.where(event_id: params[:event_id]) if params[:event_id].present?

    orders = orders.order(created_at: :desc)

    page = (params[:page] || 1).to_i
    per_page = (params[:per_page] || 20).to_i
    total = orders.count
    orders = orders.offset((page - 1) * per_page).limit(per_page)

    render json: {
      orders: orders.map { |o| order_json(o) },
      meta: { page: page, per_page: per_page, total: total, total_pages: (total.to_f / per_page).ceil }
    }
  end

  private

  def order_json(o)
    {
      id: o.id,
      buyer_name: o.buyer_name,
      buyer_email: o.buyer_email,
      total_cents: o.total_cents,
      subtotal_cents: o.subtotal_cents,
      service_fee_cents: o.service_fee_cents,
      discount_cents: o.discount_cents,
      refund_cents: o.refunded_cents,
      net_cents: o.net_cents,
      fee_cents: o.fee_cents,
      organizer_proceeds_cents: o.organizer_proceeds_cents,
      currency: o.currency,
      status: o.status,
      created_at: o.created_at,
      event_id: o.event_id,
      event_title: o.event&.title,
      event_slug: o.event&.slug,
      order_items: o.order_items.map { |item|
        {
          id: item.id,
          name: item.name,
          tier_name: item.tier_name,
          unit_price_cents: item.unit_price_cents,
          quantity: item.quantity,
          subtotal_cents: item.subtotal_cents,
          discount_cents: item.discount_cents,
          fee_cents: item.fee_cents,
          organizer_proceeds_cents: item.organizer_proceeds_cents
        }
      },
      payments: o.payments.map { |payment|
        {
          id: payment.id,
          provider: payment.provider,
          provider_payment_id: payment.provider_payment_id,
          amount_cents: payment.amount_cents,
          currency: payment.currency,
          status: payment.status
        }
      },
      refunds: o.refunds.map { |refund|
        {
          id: refund.id,
          provider_refund_id: refund.provider_refund_id,
          amount_cents: refund.amount_cents,
          currency: refund.currency,
          status: refund.status,
          reason: refund.reason
        }
      },
      reconciliation_exceptions: o.reconciliation_exceptions.map { |exception|
        { id: exception.id, code: exception.code, status: exception.status, created_at: exception.created_at }
      },
      tickets: o.tickets.map { |t|
        {
          id: t.id,
          ticket_type: t.ticket_type&.name,
          attendee_name: t.attendee_name,
          attendee_email: t.attendee_email,
          status: t.status,
          display_credential: t.display_credential
        }
      }
    }
  end
end
