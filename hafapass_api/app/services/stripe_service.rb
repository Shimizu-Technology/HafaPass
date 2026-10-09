# frozen_string_literal: true

require "ostruct"

class StripeService
  class PaymentError < StandardError; end

  class << self
    # ── Payment Intents ──────────────────────────────────────────────

    # Creates a PaymentIntent (real or simulated based on SiteSetting).
    # Returns an object responding to .id and .client_secret
    def create_payment_intent(order, idempotency_key:, payment: nil)
      settings = SiteSetting.instance
      raise PaymentError, "External payments are disabled in staging; select simulation mode" if
        Rails.env.staging? && !settings.simulate_mode?
      environment = payment ? payment.provider_environment : settings.payment_mode

      if environment == "simulate"
        simulate_payment_intent(order)
      else
        raise PaymentError, "Live payments are disabled until current provider evidence is independently approved" if
          environment == "live" && !settings.can_enable_live?
        client, options = operation_client(payment: payment, settings: settings)
        client.v1.payment_intents.create(
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
          options.merge(idempotency_key: idempotency_key)
        )
      end
    end

    # ── Refunds ──────────────────────────────────────────────────────

    # Refunds a PaymentIntent (full or partial).
    def refund_payment(payment_intent_id, amount_cents: nil, reason: nil, idempotency_key:, payment: nil)
      settings = SiteSetting.instance

      if simulated_operation?(payment_intent_id, payment, settings)
        unless payment_intent_id.start_with?("sim_")
          raise PaymentError, "A real payment cannot be refunded in simulation mode"
        end
        simulate_refund(payment_intent_id, amount_cents)
      else
        client, options = operation_client(payment: payment, settings: settings)
        params = { payment_intent: payment_intent_id, metadata: { hafapass_refund_key: idempotency_key } }
        params[:amount] = amount_cents if amount_cents.present?
        params[:reason] = stripe_refund_reason(reason) if reason.present?
        client.v1.refunds.create(params, options.merge(idempotency_key: idempotency_key))
      end
    end

    # The POST idempotency cache expires. Find an acknowledged operation by
    # our durable metadata before ever replaying an uncertain refund request.
    def find_refund(payment_intent_id, idempotency_key:, payment: nil)
      settings = SiteSetting.instance
      if simulated_operation?(payment_intent_id, payment, settings)
        raise PaymentError, "A real payment cannot be reconciled in simulation mode" unless payment_intent_id.start_with?("sim_")

        return nil
      end

      client, options = operation_client(payment: payment, settings: settings)
      match = nil
      client.v1.refunds.list({ payment_intent: payment_intent_id, limit: 100 }, options).auto_paging_each do |refund|
        next unless refund.metadata&.[]("hafapass_refund_key") == idempotency_key

        raise PaymentError, "Multiple provider refunds match this operation; finance review is required" if match

        match = refund
      end
      match
    end

    def cancel_payment_intent(payment_intent_id, idempotency_key:, payment: nil)
      settings = SiteSetting.instance
      if Rails.env.staging? && !payment_intent_id.start_with?("sim_")
        raise PaymentError, "Staging cannot cancel external payments"
      end
      if simulated_operation?(payment_intent_id, payment, settings)
        raise PaymentError, "A real payment cannot be cancelled in simulation mode" unless payment_intent_id.start_with?("sim_")
        return OpenStruct.new(id: payment_intent_id, status: "canceled")
      end

      client, options = operation_client(payment: payment, settings: settings)
      client.v1.payment_intents.cancel(
        payment_intent_id,
        {},
        options.merge(idempotency_key: idempotency_key)
      )
    end

    def retrieve_payment_intent(payment)
      raise PaymentError, "Payment context is missing; finance review is required" if payment.provider_environment.blank?
      raise PaymentError, "Simulated payments cannot be resumed with Stripe" if payment.provider_environment == "simulate"

      client, options = operation_client(payment: payment, settings: SiteSetting.instance)
      client.v1.payment_intents.retrieve(payment.provider_payment_id, {}, options)
    end

    # ── Query helpers ────────────────────────────────────────────────

    # True when Stripe API calls will actually be made (test or live mode).
    def payment_enabled?
      settings = SiteSetting.instance
      return false if Rails.env.staging?
      if settings.live_mode? && !settings.can_enable_live?
        raise PaymentError, "Live payments are disabled until current provider evidence is independently approved"
      end

      settings.stripe_enabled?
    end

    # Returns the publishable key the frontend should use.
    def publishable_key(payment: nil)
      return nil if Rails.env.staging?
      if payment
        return ENV["STRIPE_LIVE_PUBLISHABLE_KEY"] if payment.provider_environment == "live"
        return ENV["STRIPE_TEST_PUBLISHABLE_KEY"].presence || ENV["STRIPE_PUBLISHABLE_KEY"] if payment.provider_environment == "test"
        return nil
      end
      SiteSetting.instance.stripe_publishable_key
    end

    # Returns the current payment mode string.
    def payment_mode
      SiteSetting.instance.payment_mode
    end

    private

    def simulated_operation?(provider_id, payment, settings)
      provider_id.start_with?("sim_") || (payment ? payment.provider_environment == "simulate" : settings.simulate_mode?)
    end

    def operation_client(payment:, settings:)
      if payment
        raise PaymentError, "Payment context is missing; finance review is required" if payment.provider_environment.blank?
        raise PaymentError, "External payments are disabled in staging" if Rails.env.staging?

        environment = payment.provider_environment
        key = if environment == "live"
          ENV["STRIPE_LIVE_SECRET_KEY"]
        elsif environment == "test"
          ENV["STRIPE_TEST_SECRET_KEY"].presence || ENV["STRIPE_SECRET_KEY"]
        end
        raise PaymentError, "Stripe #{environment} credentials are unavailable" if key.blank?
      else
        key = resolve_api_key!(settings)
      end
      options = payment&.provider_account_id.present? ? { stripe_account: payment.provider_account_id } : {}
      [Stripe::StripeClient.new(key), options]
    end

    # Returns the API key for per-request Stripe calls (thread-safe).
    def resolve_api_key!(settings)
      raise PaymentError, "External payments are disabled in staging; select simulation mode" if Rails.env.staging?

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
