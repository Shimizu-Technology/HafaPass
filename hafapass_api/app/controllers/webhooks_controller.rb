# frozen_string_literal: true

class WebhooksController < ActionController::API
  # Skip Clerk auth — Stripe sends webhooks directly
  # Verification is done via webhook signature

  def stripe
    payload = request.body.read
    sig_header = request.env["HTTP_STRIPE_SIGNATURE"]

    begin
      if ENV["STRIPE_WEBHOOK_SECRET"].present?
        event = Stripe::Webhook.construct_event(
          payload, sig_header, ENV["STRIPE_WEBHOOK_SECRET"]
        )
      else
        # Development: parse without signature verification
        data = JSON.parse(payload, symbolize_names: true)
        event = Stripe::Event.construct_from(data)
      end
    rescue JSON::ParserError
      render json: { error: "Invalid payload" }, status: :bad_request
      return
    rescue Stripe::SignatureVerificationError
      render json: { error: "Invalid signature" }, status: :bad_request
      return
    end

    case event.type
    when "payment_intent.succeeded"
      handle_payment_intent_succeeded(event.data.object)
    when "payment_intent.payment_failed"
      handle_payment_intent_failed(event.data.object)
    when "charge.refunded"
      handle_charge_refunded(event.data.object)
    else
      Rails.logger.info("Unhandled Stripe event type: #{event.type}")
    end

    render json: { received: true }, status: :ok
  end

  private

  def handle_payment_intent_succeeded(payment_intent)
    order = Order.find_by(stripe_payment_intent_id: payment_intent.id)

    unless order
      Rails.logger.warn("No order found for PaymentIntent #{payment_intent.id}")
      return
    end

    return if order.completed? # Idempotency — don't process twice

    ActiveRecord::Base.transaction do
      order.update!(
        status: :completed,
        completed_at: Time.current
      )

      # Generate QR codes for all tickets
      order.tickets.each(&:generate_qr_code!)
    end

    # Send confirmation email (never breaks the webhook on failure)
    begin
      EmailService.send_order_confirmation(order)
    rescue => e
      Rails.logger.error("Failed to send confirmation email for order ##{order.id}: #{e.message}")
    end

    Rails.logger.info("Order ##{order.id} completed via webhook (PI: #{payment_intent.id})")
  end

  def handle_payment_intent_failed(payment_intent)
    order = Order.find_by(stripe_payment_intent_id: payment_intent.id)

    unless order
      Rails.logger.warn("No order found for failed PaymentIntent #{payment_intent.id}")
      return
    end

    return unless order.pending? # Only update pending orders

    order.update!(status: :cancelled)

    # Restore ticket quantities
    order.tickets.includes(:ticket_type).each do |ticket|
      ticket.ticket_type.decrement!(:quantity_sold)
      ticket.update!(status: :cancelled)
    end

    Rails.logger.info("Order ##{order.id} cancelled due to payment failure (PI: #{payment_intent.id})")
  end

  def handle_charge_refunded(charge)
    payment_intent_id = charge.payment_intent
    order = Order.find_by(stripe_payment_intent_id: payment_intent_id)

    unless order
      Rails.logger.warn("No order found for refunded charge (PI: #{payment_intent_id})")
      return
    end

    return if order.refunded? # Idempotency

    order.update!(status: :refunded)

    # Cancel all tickets and restore quantities
    order.tickets.includes(:ticket_type).each do |ticket|
      next if ticket.cancelled?
      ticket.ticket_type.decrement!(:quantity_sold)
      ticket.update!(status: :cancelled)
    end

    Rails.logger.info("Order ##{order.id} refunded via webhook (PI: #{payment_intent_id})")
  end
end
