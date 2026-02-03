# frozen_string_literal: true

class SendOrderConfirmationJob < ApplicationJob
  queue_as :emails

  # Retry with exponential backoff for transient failures
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(order_id)
    order = Order.find_by(id: order_id)
    return unless order # Order was deleted

    EmailService.send_order_confirmation(order)
    Rails.logger.info("[SendOrderConfirmationJob] Sent confirmation for order #{order_id}")
  rescue => e
    Rails.logger.error("[SendOrderConfirmationJob] Failed for order #{order_id}: #{e.message}")
    raise # Re-raise to trigger retry
  end
end
