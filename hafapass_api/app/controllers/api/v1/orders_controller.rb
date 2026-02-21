# frozen_string_literal: true

class Api::V1::OrdersController < ApplicationController
  skip_before_action :authenticate_user!
  before_action :optional_authenticate_user!

  def create
    event = Event.published.find_by(id: params[:event_id])
    unless event
      render json: { error: "Event not found" }, status: :not_found
      return
    end

    line_items = params[:line_items]
    unless line_items.is_a?(Array) && line_items.any?
      render json: { error: "line_items is required and must be a non-empty array" }, status: :unprocessable_entity
      return
    end

    unless params[:buyer_email].present? && params[:buyer_name].present?
      render json: { error: "buyer_email and buyer_name are required" }, status: :unprocessable_entity
      return
    end

    # Validate and collect ticket types with quantities
    ticket_selections = []
    line_items.each do |item|
      ticket_type = event.ticket_types.find_by(id: item[:ticket_type_id])
      unless ticket_type
        render json: { error: "Ticket type #{item[:ticket_type_id]} not found for this event" }, status: :unprocessable_entity
        return
      end

      quantity = item[:quantity].to_i
      if quantity <= 0
        render json: { error: "Quantity must be greater than 0 for #{ticket_type.name}" }, status: :unprocessable_entity
        return
      end

      if quantity > ticket_type.available_quantity
        render json: { error: "Only #{ticket_type.available_quantity} tickets available for #{ticket_type.name}" }, status: :unprocessable_entity
        return
      end

      if ticket_type.max_per_order && quantity > ticket_type.max_per_order
        render json: { error: "Maximum #{ticket_type.max_per_order} tickets per order for #{ticket_type.name}" }, status: :unprocessable_entity
        return
      end

      ticket_selections << { ticket_type: ticket_type, quantity: quantity }
    end

    # Calculate totals (using SiteSetting fees)
    settings = SiteSetting.instance
    subtotal_cents = ticket_selections.sum { |s| s[:ticket_type].current_price_cents * s[:quantity] }
    total_ticket_count = ticket_selections.sum { |s| s[:quantity] }
    service_fee_cents = (subtotal_cents * (settings.service_fee_percent / 100.0)).round + (total_ticket_count * settings.service_fee_flat_cents)

    # HP-7: Apply promo code if provided
    promo_code = nil
    discount_cents = 0
    if params[:promo_code_id].present?
      candidate = event.promo_codes.find_by(id: params[:promo_code_id])
      if candidate&.usable?
        promo_code = candidate
        discount_cents = promo_code.calculate_discount(subtotal_cents)
      end
    end

    total_cents = [subtotal_cents + service_fee_cents - discount_cents, 0].max

    stripe_mode = StripeService.payment_enabled?

    # Create order, tickets, and Stripe intent atomically in one transaction
    intent = nil
    promo_exhausted = false
    ActiveRecord::Base.transaction do
      @order = Order.create!(
        user: @current_user,
        event: event,
        promo_code: promo_code,
        status: (stripe_mode && total_cents > 0) ? :pending : :completed,
        subtotal_cents: subtotal_cents,
        service_fee_cents: service_fee_cents,
        discount_cents: discount_cents,
        total_cents: total_cents,
        buyer_email: params[:buyer_email],
        buyer_name: params[:buyer_name],
        buyer_phone: params[:buyer_phone],
        completed_at: (stripe_mode && total_cents > 0) ? nil : Time.current
      )

      ticket_selections.each do |selection|
        selection[:quantity].times do
          @order.tickets.create!(
            ticket_type: selection[:ticket_type],
            event: event
          )
        end

        selection[:ticket_type].increment!(:quantity_sold, selection[:quantity])

        # Increment the active pricing tier's quantity_sold if applicable
        active_tier = selection[:ticket_type].active_pricing_tier
        if active_tier&.quantity_based?
          active_tier.increment!(:quantity_sold, selection[:quantity])
        end
      end

      # Atomic promo code usage increment (race-safe)
      if discount_cents > 0 && promo_code
        unless promo_code.try_increment_usage!
          promo_exhausted = true
          raise ActiveRecord::Rollback
        end
      end

      # Stripe mode: create PaymentIntent within the transaction
      if stripe_mode && total_cents > 0
        intent = StripeService.create_payment_intent(@order)
        @order.update!(stripe_payment_intent_id: intent.id)
      else
        # Generate QR codes for non-Stripe orders
        @order.tickets.each(&:generate_qr_code!)
      end
    end

    # If transaction was rolled back (e.g., promo exhausted), verify via DB
    if promo_exhausted || !@order || @order.id.nil? || !Order.exists?(@order.id)
      render json: { error: "Order could not be completed. Promo code may be exhausted." }, status: :unprocessable_entity
      return
    end

    # Stripe mode: return client_secret for frontend payment
    if stripe_mode && total_cents > 0
      render json: order_json(@order).merge(
        client_secret: intent.client_secret,
        stripe_publishable_key: StripeService.publishable_key,
        payment_mode: StripeService.payment_mode
      ), status: :created
      return
    end

    # Simulate mode or free events: order already completed
    # Send confirmation email asynchronously
    EmailService.send_order_confirmation_async(@order)

    render json: order_json(@order).merge(
      payment_mode: StripeService.payment_mode
    ), status: :created
  rescue Stripe::StripeError, StripeService::PaymentError => e
    # Transaction automatically rolled back — no manual cleanup needed
    render json: { error: "Payment setup failed: #{e.message}" }, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # POST /api/v1/orders/:id/cancel
  # Cancels a pending order and frees up ticket inventory
  def cancel
    order = Order.find_by(id: params[:id])
    unless order
      render json: { error: "Order not found" }, status: :not_found
      return
    end

    # Ownership check: order must belong to the current user or match by payment intent
    if @current_user && order.user_id && order.user_id != @current_user.id
      render json: { error: "Order not found" }, status: :not_found
      return
    end

    unless order.pending?
      render json: { error: "Only pending orders can be cancelled" }, status: :unprocessable_entity
      return
    end

    ActiveRecord::Base.transaction do
      order.update!(status: :cancelled)

      order.tickets.includes(:ticket_type).each do |ticket|
        ticket.ticket_type.decrement!(:quantity_sold)
        ticket.update!(status: :cancelled)
      end
    end

    render json: { status: "cancelled" }, status: :ok
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

  def order_json(order)
    {
      id: order.id,
      event_id: order.event_id,
      status: order.status,
      subtotal_cents: order.subtotal_cents,
      service_fee_cents: order.service_fee_cents,
      discount_cents: order.discount_cents,
      total_cents: order.total_cents,
      buyer_email: order.buyer_email,
      buyer_name: order.buyer_name,
      buyer_phone: order.buyer_phone,
      completed_at: order.completed_at,
      wallet_type: order.wallet_type,
      promo_code: order.promo_code ? { id: order.promo_code.id, code: order.promo_code.code } : nil,
      tickets: order.tickets.includes(:ticket_type).map { |ticket| ticket_json(ticket) }
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
        price_cents: ticket.ticket_type.price_cents
      }
    }
  end
end
