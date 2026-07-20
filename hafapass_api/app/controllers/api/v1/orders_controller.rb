# frozen_string_literal: true

class Api::V1::OrdersController < ApplicationController
  skip_before_action :authenticate_user!, only: [:create]
  before_action :optional_authenticate_user!, only: [:create]

  def create
    event = Event.published.find_by(id: params[:event_id])
    unless event
      render json: { error: "Event not found" }, status: :not_found
      return
    end

    unless params[:buyer_email].present? && params[:buyer_name].present?
      render json: { error: "buyer_email and buyer_name are required" }, status: :unprocessable_entity
      return
    end

    result = Commerce::OrderCreator.call(
      event: event,
      line_items: params[:line_items],
      buyer_email: params[:buyer_email],
      buyer_name: params[:buyer_name],
      buyer_phone: params[:buyer_phone],
      user: @current_user,
      promo_code_id: params[:promo_code_id]
    )

    response_payload = order_json(result.order, include_tickets: result.payment_intent.nil?).merge(
      payment_mode: StripeService.payment_mode
    )
    if result.payment_intent
      response_payload.merge!(
        client_secret: result.payment_intent.client_secret,
        stripe_publishable_key: StripeService.publishable_key
      )
    end

    render json: response_payload, status: :created
  rescue Commerce::OrderCreator::CheckoutError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def cancel
    order = Order.find_by(id: params[:id])
    unless order
      render json: { error: "Order not found" }, status: :not_found
      return
    end

    unless @current_user&.admin? || (order.user_id.present? && order.user_id == @current_user&.id)
      render json: { error: "Order not found" }, status: :not_found
      return
    end

    Commerce::OrderLifecycle.cancel!(order)
    render json: { status: "cancelled" }, status: :ok
  rescue Commerce::OrderLifecycle::InvalidTransition => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def optional_authenticate_user!
    token = extract_bearer_token
    return if token.nil?

    payload = ClerkAuthenticator.verify(token)
    return if payload.nil?

    @clerk_payload = payload
    @current_user = current_user
  end

  def order_json(order, include_tickets: order.completed?)
    {
      id: order.id,
      event_id: order.event_id,
      status: order.status,
      currency: order.currency,
      subtotal_cents: order.subtotal_cents,
      service_fee_cents: order.service_fee_cents,
      discount_cents: order.discount_cents,
      total_cents: order.total_cents,
      buyer_email: order.buyer_email,
      buyer_name: order.buyer_name,
      buyer_phone: order.buyer_phone,
      completed_at: order.completed_at,
      expires_at: order.expires_at,
      wallet_type: order.wallet_type,
      promo_code: order.promo_code ? { id: order.promo_code.id, code: order.promo_code.code } : nil,
      order_items: order.order_items.order(:id).map { |item| order_item_json(item) },
      tickets: include_tickets ? order.tickets.includes(:ticket_type).map { |ticket| ticket_json(ticket) } : []
    }
  end

  def order_item_json(item)
    {
      id: item.id,
      name: item.name,
      tier_name: item.tier_name,
      unit_price_cents: item.unit_price_cents,
      quantity: item.quantity,
      subtotal_cents: item.subtotal_cents,
      discount_cents: item.discount_cents,
      fee_cents: item.fee_cents,
      tax_cents: item.tax_cents,
      organizer_proceeds_cents: item.organizer_proceeds_cents
    }
  end

  def ticket_json(ticket)
    {
      id: ticket.id,
      qr_code: ticket.qr_code,
      status: ticket.status,
      attendee_name: ticket.attendee_name,
      attendee_email: ticket.attendee_email,
      ticket_type: {
        id: ticket.ticket_type.id,
        name: ticket.ticket_type.name,
        price_cents: ticket.order_item&.unit_price_cents || ticket.ticket_type.price_cents
      }
    }
  end
end
