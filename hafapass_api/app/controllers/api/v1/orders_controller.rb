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

    # Validate buyer info
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

    # Calculate totals
    subtotal_cents = ticket_selections.sum { |s| s[:ticket_type].price_cents * s[:quantity] }
    total_ticket_count = ticket_selections.sum { |s| s[:quantity] }
    service_fee_cents = (subtotal_cents * 0.03).round + (total_ticket_count * 50)
    total_cents = subtotal_cents + service_fee_cents

    # Create order and tickets in a transaction
    ActiveRecord::Base.transaction do
      @order = Order.create!(
        user: @current_user,
        event: event,
        # STRIPE INTEGRATION: When Stripe is configured, create order as :pending
        # instead of :completed. The order transitions to :completed only after
        # successful payment confirmation via webhook.
        # Change to: status: :pending
        status: :completed,
        subtotal_cents: subtotal_cents,
        service_fee_cents: service_fee_cents,
        total_cents: total_cents,
        buyer_email: params[:buyer_email],
        buyer_name: params[:buyer_name],
        buyer_phone: params[:buyer_phone],
        # STRIPE INTEGRATION: Remove completed_at here; set it in webhook handler
        # when payment_intent.succeeded is received.
        completed_at: Time.current
      )

      ticket_selections.each do |selection|
        selection[:quantity].times do
          @order.tickets.create!(
            ticket_type: selection[:ticket_type],
            event: event
          )
        end

        # Increment quantity_sold
        selection[:ticket_type].increment!(:quantity_sold, selection[:quantity])
      end
    end

    # STRIPE INTEGRATION: When Stripe is configured, create a PaymentIntent
    # and return the client_secret to the frontend instead of completing immediately.
    #
    # if StripeService.stripe_configured?
    #   intent = StripeService.create_payment_intent(@order)
    #   @order.update!(stripe_payment_intent_id: intent.id)
    #   render json: order_json(@order).merge(client_secret: intent.client_secret), status: :created
    # else
    #   # Mock checkout: complete immediately (current behavior)
    #   render json: order_json(@order), status: :created
    # end

    # Send order confirmation email (never breaks checkout on failure)
    begin
      EmailService.send_order_confirmation(@order)
    rescue => e
      Rails.logger.error("Failed to send order confirmation email for order ##{@order.id}: #{e.message}")
    end

    render json: order_json(@order), status: :created
  rescue ActiveRecord::RecordInvalid => e
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

  def order_json(order)
    {
      id: order.id,
      event_id: order.event_id,
      status: order.status,
      subtotal_cents: order.subtotal_cents,
      service_fee_cents: order.service_fee_cents,
      total_cents: order.total_cents,
      buyer_email: order.buyer_email,
      buyer_name: order.buyer_name,
      buyer_phone: order.buyer_phone,
      completed_at: order.completed_at,
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
