# frozen_string_literal: true

require "ostruct"

class StripeService
  class PaymentError < StandardError; end
  class CardPolicyError < PaymentError; end
  class BudgetExceeded < PaymentError; end
  class AmbiguousRefund < PaymentError; end
  REFUND_LOOKUP_PAGE_LIMIT = 3

  class CallBudget
    attr_reader :calls, :limit

    def initialize(limit)
      @limit = limit
      @calls = 0
    end

    def charge!
      raise BudgetExceeded, "Stripe call budget reached" if calls >= limit

      @calls += 1
    end
  end

  class << self
    # ── Payment Intents ──────────────────────────────────────────────

    # Creates a PaymentIntent (real or simulated based on SiteSetting).
    # Returns an object responding to .id and .client_secret
    def create_payment_intent(order, idempotency_key:, payment: nil)
      settings = SiteSetting.instance
      raise PaymentError, "External payments are disabled in staging; select simulation mode" if
        Rails.env.staging? && !settings.simulate_mode? && !ProviderRehearsal.stripe_enabled?
      environment = payment ? payment.provider_environment : settings.payment_mode

      if environment == "simulate"
        simulate_payment_intent(order)
      else
        raise PaymentError, "Live payments are disabled until current Stripe live evidence is approved" if
          environment == "live" && !settings.can_enable_live?
        client, options = operation_client(payment: payment, settings: settings)
        client.v1.payment_intents.create(
          {
            amount: order.total_cents,
            currency: "usd",
            # The ten-minute inventory reservation supports card confirmation,
            # not bank methods that may settle days later. This explicit API
            # allowlist also survives future Dashboard method enablement.
            allowed_payment_method_types: ["card"],
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

    # Both fields are required: a legacy automatic intent may currently offer
    # cards yet still lack the fixed allowlist required for this release.
    def card_only_intent?(intent)
      allowed = intent.respond_to?(:allowed_payment_method_types) ? intent.allowed_payment_method_types : nil
      compatible = intent.respond_to?(:payment_method_types) ? intent.payment_method_types : nil
      allowed == ["card"] && compatible == ["card"]
    end

    def record_card_policy_mismatch!(payment)
      payment.order.reconciliation_exceptions.find_or_create_by!(payment: payment,
        code: "payment_method_policy_mismatch", status: :open)
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
    def find_refund(payment_intent_id, idempotency_key:, payment: nil, expected_amount_cents: nil,
      expected_created_at: nil, call_budget: nil)
      settings = SiteSetting.instance
      if simulated_operation?(payment_intent_id, payment, settings)
        raise PaymentError, "A real payment cannot be reconciled in simulation mode" unless payment_intent_id.start_with?("sim_")

        return nil
      end

      client, options = operation_client(payment: payment, settings: settings, call_budget: call_budget)
      matches = []
      cursor = nil
      REFUND_LOOKUP_PAGE_LIMIT.times do
        params = { payment_intent: payment_intent_id, limit: 100 }
        params[:starting_after] = cursor if cursor
        call_budget&.charge!
        page = client.v1.refunds.list(params, options)
        page.data.each do |refund|
          key = refund.metadata&.[]("hafapass_refund_key")
          next if key.present? && key != idempotency_key
          next if expected_amount_cents && refund.amount != expected_amount_cents
          next if expected_created_at && (Time.at(refund.created.to_i) - expected_created_at).abs > 1.day
          next if key.blank? && (!expected_amount_cents || !expected_created_at)

          matches << refund
          raise AmbiguousRefund, "Multiple provider refunds match this operation; manual finance review is required" if matches.length > 1
        end
        return matches.first unless page.has_more

        cursor = page.data.last&.id
        raise AmbiguousRefund, "Stripe refund pagination was incomplete; manual finance review is required" unless cursor
      end
      raise AmbiguousRefund, "Stripe refund pagination limit reached; manual finance review is required"
    end

    def retrieve_refund(refund_id, payment:, call_budget: nil)
      raise PaymentError, "Simulated refunds cannot be reconciled with Stripe" if payment.provider_environment == "simulate"

      client, options = operation_client(payment: payment, settings: SiteSetting.instance, call_budget: call_budget)
      call_budget&.charge!
      client.v1.refunds.retrieve(refund_id, {}, options)
    end

    def cancel_payment_intent(payment_intent_id, idempotency_key:, payment: nil)
      settings = SiteSetting.instance
      if Rails.env.staging? && !payment_intent_id.start_with?("sim_") && !ProviderRehearsal.stripe_enabled?
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

    def platform_account_id(environment)
      StripeCredentials.platform_account_id(environment)
    end

    # Confirms the mode's secret key belongs to the mode's platform account
    # before an administrator switches payment mode. Raises PaymentError.
    def verify_platform_credentials!(environment)
      key = StripeCredentials.secret_key(environment)
      expected = StripeCredentials.platform_account_id(environment)
      raise PaymentError, "Stripe #{environment} credentials are incomplete" unless
        StripeCredentials.secret_key_valid?(environment) && expected
      actual = Stripe::StripeClient.new(key).v1.accounts.retrieve_current.id
      unless actual == expected
        raise PaymentError, "The Stripe #{environment} secret key belongs to a different account than " \
          "#{StripeCredentials.env_name(environment, :platform_account_id)}"
      end

      true
    rescue Stripe::StripeError => e
      raise PaymentError, "Stripe could not confirm the #{environment} credentials (#{e.class.name.demodulize})"
    end

    def verify_payment_context!(payment)
      operation_client(payment: payment, settings: SiteSetting.instance)
      true
    end

    def retrieve_payment_intent(payment)
      raise PaymentError, "Payment context is missing; finance review is required" if payment.provider_environment.blank?
      raise PaymentError, "Simulated payments cannot be resumed with Stripe" if payment.provider_environment == "simulate"

      client, options = operation_client(payment: payment, settings: SiteSetting.instance)
      client.v1.payment_intents.retrieve(payment.provider_payment_id, {}, options)
    end

    def retrieve_fee_payment_intent(payment)
      client, options = operation_client(payment: payment, settings: SiteSetting.instance)
      client.v1.payment_intents.retrieve(payment.provider_payment_id,
        { expand: ["latest_charge.balance_transaction"] }, options)
    end

    # ── Query helpers ────────────────────────────────────────────────

    # True when Stripe API calls will actually be made (test or live mode).
    def payment_enabled?
      settings = SiteSetting.instance
      return false if Rails.env.staging? && !ProviderRehearsal.stripe_enabled?
      if settings.live_mode? && !settings.can_enable_live?
        raise PaymentError, "Live payments are disabled until current Stripe live evidence is approved"
      end

      settings.stripe_enabled?
    end

    # Returns the publishable key the frontend should use.
    def publishable_key(payment: nil)
      return nil if Rails.env.staging? && !ProviderRehearsal.stripe_enabled?
      return StripeCredentials.publishable_key(payment.provider_environment) if payment

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

    def operation_client(payment:, settings:, call_budget: nil)
      if payment
        raise PaymentError, "Payment context is missing; finance review is required" if payment.provider_environment.blank?
        if Rails.env.staging? && (!ProviderRehearsal.stripe_enabled? || payment.provider_environment != "test")
          raise PaymentError, "External payments are disabled in staging; only configured test-provider payments are permitted"
        end

        environment = payment.provider_environment
        key = StripeCredentials.secret_key(environment)
        raise PaymentError, "Stripe #{environment} credentials are unavailable" if key.blank?
      else
        key = resolve_api_key!(settings)
      end
      environment = payment ? payment.provider_environment : settings.payment_mode
      raise PaymentError, "Staging cannot use live Stripe credentials" if Rails.env.staging? && environment != "test"
      unless %w[test live].include?(environment) && key.start_with?("sk_#{environment}_", "rk_#{environment}_")
        raise PaymentError, "Stripe credentials do not match the payment environment"
      end
      expected_platform = payment ? payment.provider_platform_account_id : platform_account_id(environment)
      unless expected_platform&.match?(/\Aacct_[a-zA-Z0-9]+\z/)
        raise PaymentError, "Payment platform account context is missing; finance review is required"
      end
      client = Stripe::StripeClient.new(key)
      call_budget&.charge!
      actual_platform = client.v1.accounts.retrieve_current.id
      unless actual_platform == expected_platform
        raise PaymentError, "Stripe credentials belong to a different platform account; finance review is required"
      end
      options = payment&.provider_account_id.present? ? { stripe_account: payment.provider_account_id } : {}
      [client, options]
    end

    # Returns the API key for per-request Stripe calls (thread-safe).
    def resolve_api_key!(settings)
      if Rails.env.staging? && (!ProviderRehearsal.stripe_enabled? || !settings.test_mode?)
        raise PaymentError, "External payments are disabled in staging; only configured test-provider payments are permitted"
      end

      if settings.live_mode? && !settings.can_enable_live?
        raise PaymentError, "Live payments are disabled until current Stripe live evidence is approved"
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
