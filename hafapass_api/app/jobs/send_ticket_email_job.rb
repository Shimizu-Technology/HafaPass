# frozen_string_literal: true

class SendTicketEmailJob < ApplicationJob
  queue_as :emails

  # Retry with exponential backoff for transient failures
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(ticket_id, delivery_id = nil)
    ticket = Ticket.find_by(id: ticket_id)
    return unless ticket # Ticket was deleted

    delivery = MessageDelivery.find_by(id: delivery_id)
    delivery&.update!(attempts: delivery.attempts + 1)
    EmailService.send_ticket_email(ticket)
    delivery&.update!(status: :sent, sent_at: Time.current, last_error: nil)
    Rails.logger.info("[SendTicketEmailJob] Sent ticket email for ticket #{ticket_id}")
  rescue => e
    delivery&.update!(status: :failed, last_error: e.message)
    Rails.logger.error("[SendTicketEmailJob] Failed for ticket #{ticket_id}: #{e.message}")
    raise # Re-raise to trigger retry
  end
end
