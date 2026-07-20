# frozen_string_literal: true

class SendOrderConfirmationJob < ApplicationJob
  queue_as :emails

  # Retry with exponential backoff for transient failures
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(order_id, delivery_id = nil)
    order = Order.find_by(id: order_id)
    return unless order # Order was deleted

    delivery = MessageDelivery.find_by(id: delivery_id)
    delivery&.update!(attempts: delivery.attempts + 1)
    EmailService.send_order_confirmation(order)
    delivery&.update!(status: :sent, sent_at: Time.current, last_error: nil)
    Rails.logger.info("[SendOrderConfirmationJob] Sent confirmation for order #{order_id}")
  rescue => e
    delivery&.update!(status: :failed, last_error: e.message)
    Rails.logger.error("[SendOrderConfirmationJob] Failed for order #{order_id}: #{e.message}")
    raise # Re-raise to trigger retry
  end
end
