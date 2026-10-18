# frozen_string_literal: true

class SendTicketEmailJob < ApplicationJob
  queue_as :emails

  # Retry with exponential backoff for transient failures
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(ticket_id, delivery_id = nil)
    ticket = Ticket.find_by(id: ticket_id)
    return unless ticket # Ticket was deleted

    delivery = MessageDelivery.find_by(id: delivery_id, ticket_id: ticket.id, template: "ticket_delivery")
    raise MessageWirePayload::Unavailable, "Legacy ticket email requires its existing durable delivery; reconcile before sending" unless delivery

    MessageDeliveryJob.new.perform(delivery.id)
  end
end
