# frozen_string_literal: true

class CheckoutSubscriptionJob < ApplicationJob
  queue_as :default

  def perform(order_id, consent_at: nil, ip: nil, user_agent: nil)
    order = Order.find(order_id)
    # Accept the old job keyword for in-flight jobs, but trust only persisted consent.
    return unless order.platform_opt_in_at

    PlatformSubscription.call({ email: order.buyer_email, name: order.buyer_name.to_s.first(120), source: "checkout" }, ip: ip, user_agent: user_agent, consent_at: order.platform_opt_in_at)
  rescue StandardError => error
    Rails.logger.warn("Platform subscription skipped after checkout: #{error.class}")
  end
end
