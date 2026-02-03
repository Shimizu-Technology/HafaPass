# frozen_string_literal: true

class SendTicketEmailJob < ApplicationJob
  queue_as :emails

  # Retry with exponential backoff for transient failures
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(ticket_id)
    ticket = Ticket.find_by(id: ticket_id)
    return unless ticket # Ticket was deleted

    EmailService.send_ticket_email(ticket)
    Rails.logger.info("[SendTicketEmailJob] Sent ticket email for ticket #{ticket_id}")
  rescue => e
    Rails.logger.error("[SendTicketEmailJob] Failed for ticket #{ticket_id}: #{e.message}")
    raise # Re-raise to trigger retry
  end
end
