# frozen_string_literal: true

class SendOrderConfirmationJob < ApplicationJob
  queue_as :emails

  # Retry with exponential backoff for transient failures
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(order_id, delivery_id = nil)
    order = Order.find_by(id: order_id)
    return unless order # Order was deleted

    delivery = MessageDelivery.find_by(id: delivery_id, order_id: order.id, template: %w[order_confirmation fulfillment_resend])
    raise MessageWirePayload::Unavailable, "Legacy order email requires its existing durable delivery; reconcile before sending" unless delivery

    MessageDeliveryJob.new.perform(delivery.id)
  end
end
