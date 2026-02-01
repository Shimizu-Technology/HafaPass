# frozen_string_literal: true

class StripeService
  class PaymentError < StandardError; end

  class << self
    # ── Payment Intents ──────────────────────────────────────────────

    # Creates a PaymentIntent (real or simulated based on SiteSetting).
    # Returns an object responding to .id and .client_secret
    def create_payment_intent(order)
      settings = SiteSetting.instance

      if settings.simulate_mode?
        simulate_payment_intent(order)
      else
        configure_stripe!(settings)
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
    end

    # ── Refunds ──────────────────────────────────────────────────────

    # Refunds a PaymentIntent (full or partial).
    def refund_payment(payment_intent_id, amount_cents: nil, reason: nil)
      settings = SiteSetting.instance

      if settings.simulate_mode?
        simulate_refund(payment_intent_id, amount_cents)
      else
        configure_stripe!(settings)
        params = { payment_intent: payment_intent_id }
        params[:amount] = amount_cents if amount_cents.present?
        params[:reason] = reason if reason.present?
        Stripe::Refund.create(params)
      end
    end

    # ── Query helpers ────────────────────────────────────────────────

    # True when Stripe API calls will actually be made (test or live mode).
    def payment_enabled?
      SiteSetting.instance.stripe_enabled?
    end

    # Returns the publishable key the frontend should use.
    def publishable_key
      SiteSetting.instance.stripe_publishable_key
    end

    # Returns the current payment mode string.
    def payment_mode
      SiteSetting.instance.payment_mode
    end

    private

    # Sets Stripe.api_key to the correct key for the current mode.
    def configure_stripe!(settings)
      key = settings.stripe_secret_key
      if key.blank?
        raise PaymentError, "Stripe secret key not configured for #{settings.payment_mode} mode"
      end
      Stripe.api_key = key
    end

    # ── Simulate helpers ─────────────────────────────────────────────

    def simulate_payment_intent(order)
      Rails.logger.info "\U0001f7e1 SIMULATE: PaymentIntent for Order ##{order.id} ($#{'%.2f' % (order.total_cents / 100.0)})"
      sleep(0.3) # Mimic network latency

      OpenStruct.new(
        id: "sim_pi_#{SecureRandom.hex(12)}",
        client_secret: "sim_secret_#{SecureRandom.hex(16)}"
      )
    end

    def simulate_refund(payment_intent_id, amount_cents)
      amount_str = amount_cents ? "$#{'%.2f' % (amount_cents / 100.0)}" : "full"
      Rails.logger.info "\U0001f7e1 SIMULATE: Refund #{amount_str} for #{payment_intent_id}"
      sleep(0.2)

      OpenStruct.new(
        id: "sim_re_#{SecureRandom.hex(12)}",
        status: "succeeded"
      )
    end
  end
end
