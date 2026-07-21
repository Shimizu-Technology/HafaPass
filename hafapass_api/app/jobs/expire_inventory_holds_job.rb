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
      transfer.with_lock do
        transfer.update!(status: :expired, token_version: transfer.token_version + 1) if transfer.pending?
      end
    end
  end
end
