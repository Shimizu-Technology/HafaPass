# frozen_string_literal: true

class Api::V1::OrdersController < ApplicationController
  skip_before_action :authenticate_user!, only: [
    :create, :show, :cancel, :resend, :event_change_response, :rotate_scan, :cancel_ticket
  ]
  before_action :optional_authenticate_user!, only: [
    :create, :show, :cancel, :resend, :event_change_response, :rotate_scan, :cancel_ticket
  ]
  before_action :set_accessible_order, only: [
    :show, :cancel, :resend, :event_change_response, :rotate_scan, :cancel_ticket
  ]

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

    response_payload = OrderPresenter.call(
      result.order,
      include_tickets: result.payment_intent.nil?,
      guest_access_token: result.guest_access_token
    ).merge(
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

  def show
    render json: OrderPresenter.call(
      @order,
      include_tickets: @order.completed? || @order.partially_refunded? || @order.refunded? || @order.cancelled?
    )
  end

  def cancel
    Commerce::OrderLifecycle.cancel!(@order)
    render json: { status: "cancelled" }, status: :ok
  rescue Commerce::OrderLifecycle::InvalidTransition => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def resend
    delivery = FulfillmentResender.call(order: @order, requested_by: @current_user)
    render json: { message: "Tickets sent", delivery_id: delivery.id }, status: :accepted
  rescue FulfillmentResender::Cooldown => e
    render json: { error: e.message }, status: :too_many_requests
  rescue FulfillmentResender::NotAvailable => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def rotate_scan
    ticket = @order.tickets.find_by(id: params[:ticket_id])
    return render json: { error: "Ticket not found" }, status: :not_found unless ticket

    rotated = ticket.with_lock do
      next false unless ticket.issued? && !@order.ticket_access_blocked?

      ticket.rotate_scan_credential!
      true
    end
    return render json: { error: "Only active tickets can refresh their entry code" }, status: :unprocessable_entity unless rotated

    render json: { scan_credential: ticket.scan_credential }
  end

  def cancel_ticket
    ticket = @order.tickets.find_by(id: params[:ticket_id])
    return render json: { error: "Ticket not found" }, status: :not_found unless ticket
    return render json: { error: "Ticket is already cancelled" }, status: :unprocessable_entity if ticket.cancelled?
    return render json: { error: "Used or transferred tickets cannot be cancelled" }, status: :unprocessable_entity unless ticket.issued?

    if ticket.refundable_cents.zero?
      cancel_free_ticket!(ticket, reason: "buyer_cancelled")
      return render json: OrderPresenter.call(@order.reload, include_tickets: true)
    end

    unless @order.event.cancelled? || @order.event.postponed?
      return render json: { error: "Paid self-service refunds are available after an event is cancelled or postponed" },
        status: :unprocessable_entity
    end

    idempotency_key = request.headers["Idempotency-Key"].presence
    return render json: { error: "Idempotency-Key header is required" }, status: :unprocessable_entity unless idempotency_key

    refund = Commerce::RefundCreator.call(
      order: @order,
      tickets: [ticket],
      reason: "buyer_ticket_cancellation",
      requested_by: @current_user,
      idempotency_key: idempotency_key
    )
    render json: { refund_id: refund.id, order: OrderPresenter.call(@order.reload, include_tickets: true) }, status: :created
  rescue Commerce::RefundCreator::RefundError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def event_change_response
    change = @order.event.event_changes.find_by(id: params[:event_change_id])
    return render json: { error: "Event change not found" }, status: :not_found unless change

    decision = params[:decision].to_s
    unless EventChangeResponse::DECISIONS.include?(decision)
      return render json: { error: "Decision must be accepted or refund_requested" }, status: :unprocessable_entity
    end

    existing_response = change.event_change_responses.find_by(order: @order)
    if existing_response && existing_response.decision != decision
      return render json: { error: "This event-change response has already been recorded" }, status: :unprocessable_entity
    end

    if decision == "refund_requested"
      idempotency_key = request.headers["Idempotency-Key"].presence
      return render json: { error: "Idempotency-Key header is required" }, status: :unprocessable_entity unless idempotency_key
    end

    response = existing_response || change.event_change_responses.create!(
      order: @order,
      decision: decision,
      responded_at: Time.current
    )

    if decision == "refund_requested"
      refundable_tickets = @order.tickets.where(status: :issued).to_a
      paid_tickets = refundable_tickets.select { |ticket| ticket.refundable_cents.positive? }
      free_tickets = refundable_tickets - paid_tickets
      Commerce::RefundCreator.call(
        order: @order,
        tickets: paid_tickets,
        reason: "event_change_refund",
        requested_by: @current_user,
        idempotency_key: idempotency_key
      ) if paid_tickets.any?
      free_tickets.each do |ticket|
        cancel_free_ticket!(ticket, reason: "event_change_refund")
      end
    end

    render json: { decision: response.decision, order: OrderPresenter.call(@order.reload, include_tickets: true) }
  rescue ActiveRecord::RecordNotUnique
    render json: { error: "This event-change response has already been recorded" }, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  rescue Commerce::RefundCreator::RefundError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def cancel_free_ticket!(ticket, reason:)
    ticket.order.with_lock do
      ticket.lock!
      raise Commerce::RefundCreator::RefundError, "Only unused active tickets can be cancelled" unless ticket.issued?

      ticket.release_inventory!
      ticket.update!(
        status: :cancelled,
        cancelled_at: Time.current,
        cancellation_reason: reason,
        scan_credential_version: ticket.scan_credential_version + 1
      )
      unless ticket.order.tickets.where.not(id: ticket.id).where.not(status: :cancelled).exists?
        ticket.order.update!(status: :cancelled)
      end
    end
    ticket.event.notify_waitlist_if_available
  end

  def set_accessible_order
    order = Order.find_by(id: params[:id])
    authorized = order && (
      @current_user&.admin? ||
      (order.user_id.present? && order.user_id == @current_user&.id) ||
      GuestOrderAccess.find(guest_access_token)&.id == order.id
    )
    return @order = order if authorized

    render json: { error: "Order not found" }, status: :not_found
  end

  def guest_access_token
    request.headers["X-Guest-Order-Token"].presence || (params[:guest_token].presence if action_name == "show")
  end
end
