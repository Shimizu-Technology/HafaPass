# frozen_string_literal: true

class Api::V1::Support::MessageDeliveriesController < Api::V1::Support::BaseController
  def index
    deliveries = MessageDelivery.includes(:order, :ticket, :event, :requested_by)
    deliveries = deliveries.where(status: params[:status]) if params[:status].present?
    deliveries = deliveries.where(order_id: params[:order_id]) if params[:order_id].present?
    deliveries = deliveries.where(event_id: params[:event_id]) if params[:event_id].present?
    deliveries = deliveries.order(created_at: :desc).limit(100)

    render json: { deliveries: deliveries.map { |delivery| delivery_json(delivery) } }
  end

  def resend
    delivery = MessageDelivery.find(params[:id])
    unless delivery.retryable?
      return render json: { error: "Only failed pre-provider deliveries can be safely replayed" },
        status: :unprocessable_entity
    end
    if delivery.suppressed_recipient?
      return render json: { error: "Recipient is suppressed after a bounce or complaint" },
        status: :unprocessable_entity
    end

    MessageDeliveryJob.perform_later(delivery.id)
    AuditLogger.record!(action: "message_delivery.replayed", auditable: delivery, actor: current_user,
      request: request)
    render json: delivery_json(delivery.reload), status: :accepted
  end

  def fulfill
    order = Order.find(params[:order_id])
    delivery = FulfillmentResender.call(order: order, requested_by: current_user)
    AuditLogger.record!(action: "order.fulfillment_resent", auditable: order, actor: current_user,
      metadata: { message_delivery_id: delivery.id }, request: request)
    render json: delivery_json(delivery), status: :accepted
  rescue FulfillmentResender::ResendError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def delivery_json(delivery)
    {
      id: delivery.id,
      order_id: delivery.order_id,
      ticket_id: delivery.ticket_id,
      event_id: delivery.event_id,
      template: delivery.template,
      recipient: delivery.recipient,
      provider: delivery.provider,
      provider_id: delivery.provider_id,
      status: delivery.status,
      attempts: delivery.attempts,
      last_error: delivery.last_error,
      sent_at: delivery.sent_at,
      delivered_at: delivery.delivered_at,
      bounced_at: delivery.bounced_at,
      complained_at: delivery.complained_at,
      suppressed_at: delivery.suppressed_at,
      requested_by: delivery.requested_by&.email,
      created_at: delivery.created_at
    }
  end
end
