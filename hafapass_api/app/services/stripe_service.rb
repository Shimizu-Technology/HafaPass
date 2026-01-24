class StripeService
  class << self
    # Creates a Stripe PaymentIntent for the given order.
    # Returns the PaymentIntent object with client_secret for frontend confirmation.
    #
    # In production, the frontend would use the client_secret with Stripe.js
    # to collect payment details and confirm the payment.
    #
    # Usage:
    #   intent = StripeService.create_payment_intent(order)
    #   # Return intent.client_secret to frontend
    def create_payment_intent(order)
      return nil unless stripe_configured?

      Stripe::PaymentIntent.create(
        amount: order.total_cents,
        currency: "usd",
        metadata: {
          order_id: order.id,
          event_id: order.event_id,
          buyer_email: order.buyer_email
        }
      )
    end

    # Confirms a payment was successful by retrieving the PaymentIntent.
    # Returns the PaymentIntent object if status is "succeeded", nil otherwise.
    #
    # In production, this would be called from a Stripe webhook handler
    # (payment_intent.succeeded) to finalize the order.
    #
    # Usage:
    #   intent = StripeService.confirm_payment(payment_intent_id)
    #   if intent
    #     order.update!(status: :completed, completed_at: Time.current)
    #   end
    def confirm_payment(payment_intent_id)
      return nil unless stripe_configured?

      intent = Stripe::PaymentIntent.retrieve(payment_intent_id)
      intent.status == "succeeded" ? intent : nil
    end

    # Returns true if Stripe is configured with an API key.
    def stripe_configured?
      ENV["STRIPE_SECRET_KEY"].present?
    end
  end
end
