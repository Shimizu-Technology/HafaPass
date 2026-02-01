# frozen_string_literal: true

class StripeService
  class << self
    # Creates a Stripe PaymentIntent for the given order.
    # Returns the PaymentIntent object with client_secret for frontend confirmation.
    def create_payment_intent(order)
      Stripe::PaymentIntent.create(
        amount: order.total_cents,
        currency: "usd",
        automatic_payment_methods: { enabled: true },
        metadata: {
          order_id: order.id,
          event_id: order.event_id,
          buyer_email: order.buyer_email,
          hafapass: "true"
        },
        receipt_email: order.buyer_email,
        description: "HafaPass tickets for #{order.event.title}"
      )
    end

    # Refunds a PaymentIntent (full or partial).
    # Returns the Refund object on success.
    def refund_payment(payment_intent_id, amount_cents: nil, reason: nil)
      params = { payment_intent: payment_intent_id }
      params[:amount] = amount_cents if amount_cents.present?
      params[:reason] = reason if reason.present?

      Stripe::Refund.create(params)
    end

    # Returns true if Stripe is configured with an API key.
    def stripe_configured?
      ENV["STRIPE_SECRET_KEY"].present?
    end
  end
end
