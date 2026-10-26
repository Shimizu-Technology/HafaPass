# frozen_string_literal: true

class ExpireInventoryHoldsJob < ApplicationJob
  queue_as :default

  def perform(now = Time.current)
    Order.pending.where(expires_at: ..now).find_each do |order|
      Commerce::OrderLifecycle.expire!(order, at: now)
    rescue StandardError => e
      Sentry.capture_exception(e)
      Rails.logger.error({ event: "order_expiry_failed", order_id: order.id, error_class: e.class.name }.to_json)
    end
    WaitlistOffer.where(status: :offered, expires_at: ..now).find_each { |offer| offer.expire!(at: now) }
    TicketTransfer.pending.where(expires_at: ..now).find_each do |transfer|
      TicketTransfers::Manager.expire!(transfer, at: now)
    rescue StandardError => e
      Sentry.capture_exception(e)
      Rails.logger.error({ event: "ticket_transfer_expiry_failed", ticket_transfer_id: transfer.id, error_class: e.class.name }.to_json)
    end
  end
end
