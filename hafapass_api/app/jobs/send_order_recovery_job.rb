# frozen_string_literal: true

class SendOrderRecoveryJob < ApplicationJob
  queue_as :emails

  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(order_id, delivery_id)
    order = Order.find_by(id: order_id)
    delivery = MessageDelivery.find_by(id: delivery_id)
    return unless order && delivery

    delivery.update!(attempts: delivery.attempts + 1)
    EmailService.send_order_recovery(order)
    delivery.update!(status: :sent, sent_at: Time.current, last_error: nil)
  rescue => e
    delivery&.update!(status: :failed, last_error: e.message)
    raise
  end
end
