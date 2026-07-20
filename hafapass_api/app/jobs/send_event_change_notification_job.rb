# frozen_string_literal: true

class SendEventChangeNotificationJob < ApplicationJob
  queue_as :emails

  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(event_change_id, order_id, delivery_id)
    change = EventChange.find_by(id: event_change_id)
    order = Order.find_by(id: order_id)
    delivery = MessageDelivery.find_by(id: delivery_id)
    return unless change && order && delivery

    delivery.update!(attempts: delivery.attempts + 1)
    EmailService.send_event_change_notification(change, order)
    delivery.update!(status: :sent, sent_at: Time.current, last_error: nil)
  rescue => e
    delivery&.update!(status: :failed, last_error: e.message)
    raise
  end
end
