# frozen_string_literal: true

class CheckoutSubscriptionJob < ApplicationJob
  queue_as :marketing

  def perform(order_id)
    order = Order.find(order_id)
    PlatformSubscription.call({ email: order.buyer_email, name: order.buyer_name.to_s.first(120), source: "checkout" })
  rescue StandardError => error
    Rails.logger.warn("Platform subscription skipped after checkout: #{error.class}")
  end
end
