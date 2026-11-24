# frozen_string_literal: true

class CheckoutSubscriptionJob < ApplicationJob
  queue_as :default

  def perform(order_id, consent_at:, ip: nil, user_agent: nil)
    order = Order.find(order_id)
    PlatformSubscription.call({ email: order.buyer_email, name: order.buyer_name.to_s.first(120), source: "checkout" }, ip: ip, user_agent: user_agent, consent_at: Time.iso8601(consent_at))
  rescue StandardError => error
    Rails.logger.warn("Platform subscription skipped after checkout: #{error.class}")
  end
end
