# frozen_string_literal: true

require "ostruct"

class StripeService
  class PaymentError < StandardError; end

  class << self
    # ── Payment Intents ──────────────────────────────────────────────

    # Creates a PaymentIntent (real or simulated based on SiteSetting).
    # Returns an object responding to .id and .client_secret
    def create_payment_intent(order, idempotency_key:)
      settings = SiteSetting.instance

      if settings.simulate_mode?
        simulate_payment_intent(order)
      else
        api_key = resolve_api_key!(settings)
        Stripe::PaymentIntent.create(
          {
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
          },
          { api_key: api_key, idempotency_key: idempotency_key }
        )
      end
    end

    # ── Refunds ──────────────────────────────────────────────────────

    # Refunds a PaymentIntent (full or partial).
    def refund_payment(payment_intent_id, amount_cents: nil, reason: nil, idempotency_key:)
      settings = SiteSetting.instance

      if settings.simulate_mode?
        simulate_refund(payment_intent_id, amount_cents)
      else
        api_key = resolve_api_key!(settings)
        params = { payment_intent: payment_intent_id }
        params[:amount] = amount_cents if amount_cents.present?
        params[:reason] = stripe_refund_reason(reason) if reason.present?
        Stripe::Refund.create(params, { api_key: api_key, idempotency_key: idempotency_key })
      end
    end

    def cancel_payment_intent(payment_intent_id, idempotency_key:)
      settings = SiteSetting.instance
      if settings.simulate_mode? || payment_intent_id.start_with?("sim_")
        return OpenStruct.new(id: payment_intent_id, status: "canceled")
      end

      api_key = resolve_api_key!(settings)
      Stripe::PaymentIntent.cancel(
        payment_intent_id,
        {},
        { api_key: api_key, idempotency_key: idempotency_key }
      )
    end

    # ── Query helpers ────────────────────────────────────────────────

    # True when Stripe API calls will actually be made (test or live mode).
    def payment_enabled?
      settings = SiteSetting.instance
      if settings.live_mode? && !settings.can_enable_live?
        raise PaymentError, "Live payments are disabled until current provider evidence is independently approved"
      end

      settings.stripe_enabled?
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

    # Returns the API key for per-request Stripe calls (thread-safe).
    def resolve_api_key!(settings)
      if settings.live_mode? && !settings.can_enable_live?
        raise PaymentError, "Live payments are disabled until current provider evidence is independently approved"
      end
      key = settings.stripe_secret_key
      if key.blank?
        raise PaymentError, "Stripe secret key not configured for #{settings.payment_mode} mode"
      end
      key
    end

    def stripe_refund_reason(reason)
      allowed_reasons = %w[duplicate fraudulent requested_by_customer]
      allowed_reasons.include?(reason) ? reason : "requested_by_customer"
    end

    # ── Simulate helpers ─────────────────────────────────────────────

    def simulate_payment_intent(order)
      Rails.logger.info "\U0001f7e1 SIMULATE: PaymentIntent for Order ##{order.id} ($#{'%.2f' % (order.total_cents / 100.0)})"
      sleep(0.3) unless Rails.env.test? # Mimic network latency

      OpenStruct.new(
        id: "sim_pi_#{SecureRandom.hex(12)}",
        client_secret: "sim_secret_#{SecureRandom.hex(16)}"
      )
    end

    def simulate_refund(payment_intent_id, amount_cents)
      amount_str = amount_cents ? "$#{'%.2f' % (amount_cents / 100.0)}" : "full"
      Rails.logger.info "\U0001f7e1 SIMULATE: Refund #{amount_str} for #{payment_intent_id}"
      sleep(0.2) unless Rails.env.test?

      OpenStruct.new(
        id: "sim_re_#{SecureRandom.hex(12)}",
        status: "succeeded"
      )
    end
  end
end
