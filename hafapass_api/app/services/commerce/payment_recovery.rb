# frozen_string_literal: true

require "timeout"

module Commerce
  class PaymentRecovery
    class RecoveryError < StandardError; end
    Result = Data.define(:order, :payment_intent, :payment_state, :publishable_key)
    RESUMABLE = %w[requires_payment_method requires_confirmation requires_action].freeze
    PROVIDER_REQUEST_TIMEOUT = 30.seconds

    def self.call(order:)
      new(order).call
    end

    def initialize(order)
      @order = order
    end

    def call
      card_policy_blocked = false
      expired = false
      snapshot = @order.with_lock do
        payment = @order.payments.order(:id).last
        return result(nil, nil) unless @order.pending?
        if @order.expires_at.present? && @order.expires_at <= Time.current
          expired = true
          next
        end
        verify_reservation!
        unless payment&.provider == "stripe" && payment.provider_payment_id.present? && payment.pending?
          raise RecoveryError, "Payment setup is incomplete; retry the original checkout request"
        end
        { payment_id: payment.id, provider_id: payment.provider_payment_id }
      end
      return expire_reservation! if expired

      payment = Payment.find(snapshot.fetch(:payment_id))
      # Account verification and provider retrieval must not hold the order's
      # row lock. Reload the reservation and exact payment identity afterwards.
      intent = Timeout.timeout(PROVIDER_REQUEST_TIMEOUT) { StripeService.retrieve_payment_intent(payment) }
      recovery = @order.with_lock do
        payment = @order.payments.order(:id).last
        payment&.lock!
        return result(nil, nil) unless @order.pending?
        if @order.expires_at.present? && @order.expires_at <= Time.current
          expired = true
          next
        end
        verify_reservation!
        unless payment&.pending? && payment.id == snapshot[:payment_id] && payment.provider_payment_id == snapshot[:provider_id]
          raise RecoveryError, "Payment setup changed during recovery; retry the original checkout request"
        end
        unless payment.amount_cents == @order.total_cents && payment.currency == @order.currency &&
            intent.id == payment.provider_payment_id && intent.amount == payment.amount_cents &&
            intent.currency.to_s.downcase == payment.currency &&
            intent.livemode == (payment.provider_environment == "live")
          raise RecoveryError, "Payment details do not match this order; contact support"
        end
        state = intent.status
        payment.update!(provider_payload: payment.provider_payload.to_h.merge("status" => state))
        if state == "succeeded"
          OrderLifecycle.complete!(@order, payment: payment, provider_amount_cents: intent.amount_received,
            provider_currency: intent.currency)
        elsif state == "canceled"
          OrderLifecycle.fail!(@order, payment: payment, reason: "payment_cancelled")
        end
        resumable = @order.pending? && RESUMABLE.include?(state) && @order.expires_at&.future?
        if resumable && (!@order.event.sales_open? || @order.event.production_release_gate_status != :ready ||
            (Rails.env.production? && !PolicyRegistry.production_approved?))
          raise RecoveryError, "Payment confirmation is unavailable for this event; contact support"
        end
        if resumable && payment.provider_environment == "live" && !SiteSetting.instance.can_enable_live?
          raise RecoveryError, "Live payment confirmation is unavailable; contact support"
        end
        if resumable && !StripeService.card_only_intent?(intent)
          StripeService.record_card_policy_mismatch!(payment)
          card_policy_blocked = true
          next
        end
        key = StripeService.publishable_key(payment: payment)
        raise RecoveryError, "Payment configuration is unavailable; contact support" if resumable && key.blank?

        result(resumable ? intent : nil, state, key)
      end
      return expire_reservation! if expired

      # Raise only after committing the reconciliation hold; raising inside the
      # order lock transaction would roll the evidence back.
      if card_policy_blocked
        raise RecoveryError, "This saved payment configuration needs support review. No additional payment was submitted"
      end
      recovery
    rescue Stripe::StripeError, StripeService::PaymentError, IOError, Timeout::Error => e
      raise RecoveryError, e.message
    end

    private

    def verify_reservation!
      unless @order.expires_at&.future? && @order.inventory_holds.active.exists? &&
          !@order.inventory_holds.active.where("expires_at <= ?", Time.current).exists?
        raise RecoveryError, "The ticket reservation is unavailable; contact support"
      end
    end

    def expire_reservation!
      OrderLifecycle.expire!(@order)
      result(nil, nil)
    end

    def result(intent, state, key = nil)
      Result.new(order: @order.reload, payment_intent: intent, payment_state: state, publishable_key: key)
    end
  end
end
