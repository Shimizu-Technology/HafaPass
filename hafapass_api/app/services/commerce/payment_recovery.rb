# frozen_string_literal: true

module Commerce
  class PaymentRecovery
    class RecoveryError < StandardError; end
    Result = Data.define(:order, :payment_intent, :payment_state, :publishable_key)
    RESUMABLE = %w[requires_payment_method requires_confirmation requires_action].freeze

    def self.call(order:)
      new(order).call
    end

    def initialize(order)
      @order = order
    end

    def call
      @order.with_lock do
        payment = @order.payments.order(:id).last
        return result(nil, nil) unless @order.pending?
        if @order.expires_at.present? && @order.expires_at <= Time.current
          OrderLifecycle.expire!(@order)
          return result(nil, nil)
        end
        unless @order.expires_at&.future? && @order.inventory_holds.active.exists? &&
            !@order.inventory_holds.active.where("expires_at <= ?", Time.current).exists?
          raise RecoveryError, "The ticket reservation is unavailable; contact support"
        end
        unless payment&.provider == "stripe" && payment.provider_payment_id.present? && payment.pending?
          raise RecoveryError, "Payment setup is incomplete; retry the original checkout request"
        end
        intent = StripeService.retrieve_payment_intent(payment)
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
        key = StripeService.publishable_key(payment: payment)
        raise RecoveryError, "Payment configuration is unavailable; contact support" if resumable && key.blank?

        result(resumable ? intent : nil, state, key)
      end
    rescue Stripe::StripeError, StripeService::PaymentError => e
      raise RecoveryError, e.message
    end

    private

    def result(intent, state, key = nil)
      Result.new(order: @order.reload, payment_intent: intent, payment_state: state, publishable_key: key)
    end
  end
end
