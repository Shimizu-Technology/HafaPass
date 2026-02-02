# frozen_string_literal: true
require "ostruct"

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
        # Development/test only: parse without signature verification
        if Rails.env.development? || Rails.env.test?
          data = JSON.parse(payload, symbolize_names: true)
          event = Stripe::Event.construct_from(data)
        else
          render json: { error: "Webhook secret not configured" }, status: :bad_request
          return
        end
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
    when "checkout.session.completed"
      handle_checkout_session_completed(event.data.object)
    when "charge.dispute.created"
      handle_dispute_created(event.data.object)
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

    return if order.completed? # Idempotency

    ActiveRecord::Base.transaction do
      # Detect wallet type from payment method (HP-14)
      wallet_type = detect_wallet_type(payment_intent)

      order.update!(
        status: :completed,
        completed_at: Time.current,
        wallet_type: wallet_type
      )

      order.tickets.each(&:generate_qr_code!)
    end

    # Send confirmation email (never breaks the webhook on failure)
    begin
      EmailService.send_order_confirmation(order)
      order.tickets.each do |ticket|
        EmailService.send_ticket_email(ticket) if ticket.attendee_email.present?
      end
    rescue => e
      Rails.logger.error("Failed to send emails for order ##{order.id}: #{e.message}")
    end

    Rails.logger.info("Order ##{order.id} completed via webhook (PI: #{payment_intent.id}, wallet: #{order.wallet_type || 'card'})")
  end

  def handle_payment_intent_failed(payment_intent)
    order = Order.find_by(stripe_payment_intent_id: payment_intent.id)

    unless order
      Rails.logger.warn("No order found for failed PaymentIntent #{payment_intent.id}")
      return
    end

    return unless order.pending?

    ActiveRecord::Base.transaction do
      order.update!(status: :cancelled)

      order.tickets.includes(:ticket_type).each do |ticket|
        ticket.ticket_type.decrement!(:quantity_sold)
        ticket.update!(status: :cancelled)
      end
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

    # Determine if full or partial refund
    refund_amount = charge.amount_refunded
    is_full_refund = refund_amount >= order.total_cents

    if is_full_refund
      return if order.refunded? # Idempotency

      ActiveRecord::Base.transaction do
        order.update!(
          status: :refunded,
          refund_amount_cents: refund_amount,
          refunded_at: Time.current
        )

        order.tickets.includes(:ticket_type).each do |ticket|
          next if ticket.cancelled?
          ticket.ticket_type.decrement!(:quantity_sold)
          ticket.update!(status: :cancelled)
        end
      end
    else
      order.update!(
        status: :partially_refunded,
        refund_amount_cents: refund_amount,
        refunded_at: Time.current
      )
    end

    # Send refund notification email
    begin
      EmailService.send_refund_notification(order)
    rescue => e
      Rails.logger.error("Failed to send refund email for order ##{order.id}: #{e.message}")
    end

    Rails.logger.info("Order ##{order.id} #{is_full_refund ? 'fully' : 'partially'} refunded via webhook (PI: #{payment_intent_id})")
  end

  def handle_checkout_session_completed(session)
    # Handle Checkout Sessions (if used for future flows)
    payment_intent_id = session.payment_intent
    return unless payment_intent_id

    order = Order.find_by(stripe_payment_intent_id: payment_intent_id)
    return unless order
    return if order.completed?

    # Delegate to payment_intent.succeeded handler logic
    handle_payment_intent_succeeded(
      OpenStruct.new(id: payment_intent_id)
    )
  end

  def handle_dispute_created(dispute)
    payment_intent_id = dispute.payment_intent
    order = Order.find_by(stripe_payment_intent_id: payment_intent_id)

    if order
      Rails.logger.warn("DISPUTE created for Order ##{order.id} (PI: #{payment_intent_id})")
      # Future: notify organizer, freeze tickets, etc.
    end
  end

  # HP-14: Detect Apple Pay / Google Pay from payment method details
  def detect_wallet_type(payment_intent)
    return nil unless payment_intent.respond_to?(:payment_method)

    pm_id = payment_intent.payment_method
    return nil if pm_id.blank?

    begin
      pm = Stripe::PaymentMethod.retrieve(pm_id)
      wallet = pm&.card&.wallet
      return nil unless wallet

      case wallet.type
      when "apple_pay" then "apple_pay"
      when "google_pay" then "google_pay"
      else wallet.type
      end
    rescue => e
      Rails.logger.warn("Could not detect wallet type: #{e.message}")
      nil
    end
  end
end
