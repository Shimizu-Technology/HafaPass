# frozen_string_literal: true

class ExpireInventoryHoldsJob < ApplicationJob
  queue_as :default

  # Runs every minute. Expiring an order can call Stripe (check whether the
  # payment already succeeded, then cancel the PaymentIntent), so stop starting
  # new orders after this long and leave the rest for the next run. Holds stop
  # counting against inventory at expires_at whether or not this job has run
  # (InventoryHold.current), so a deferred order never blocks buyers.
  RUN_BUDGET = 45.seconds

  def perform(now = Time.current, budget: RUN_BUDGET)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    deferred = 0
    Order.pending.where(expires_at: ..now).find_each do |order|
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started >= budget.to_f
        deferred += 1
        next
      end

      Commerce::OrderLifecycle.expire!(order, at: now)
    rescue StandardError => e
      Sentry.capture_exception(e)
      Rails.logger.error({ event: "order_expiry_failed", order_id: order.id, error_class: e.class.name }.to_json)
    end
    if deferred.positive?
      Rails.logger.warn({ event: "order_expiry_budget_exhausted", deferred_orders: deferred,
        budget_seconds: budget.to_f }.to_json)
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
