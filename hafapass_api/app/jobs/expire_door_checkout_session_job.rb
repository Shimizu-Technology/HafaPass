# frozen_string_literal: true

require "timeout"

class ExpireDoorCheckoutSessionJob < ApplicationJob
  retry_on Stripe::StripeError, StripeService::PaymentError, IOError, Timeout::Error,
    wait: :polynomially_longer, attempts: 5

  def perform(payment_id)
    payment = Payment.find_by(id: payment_id)
    return unless payment&.stripe_checkout_session_id && payment.order.online_door_card?
    return unless payment.order.expired? || payment.order.cancelled?

    session = Timeout.timeout(Commerce::OnlineDoorSale::PROVIDER_TIMEOUT) do
      StripeService.expire_door_checkout_session(payment: payment, session_id: payment.stripe_checkout_session_id)
    end
    unless session.id == payment.stripe_checkout_session_id &&
        session.livemode == (payment.provider_environment == "live") && %w[expired complete].include?(session.status)
      raise StripeService::PaymentError, "Stripe did not confirm the door session is closed"
    end
  end
end
