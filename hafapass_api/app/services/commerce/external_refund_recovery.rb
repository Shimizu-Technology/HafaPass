# frozen_string_literal: true

module Commerce
  class ExternalRefundRecovery
    RECOVERABLE_CODES = %w[refund_operation_not_found refund_aggregate_requires_reconciliation].freeze

    # Call only with a verified webhook's payment context or an authenticated
    # Stripe lookup scoped to the payment's immutable account/environment.
    def self.ingest!(payment:, provider_refund:)
      object = provider_refund
      read = ->(key) { object.respond_to?(key) ? object.public_send(key) : object[key.to_s] || object[key] }
      id, amount, currency, intent = %i[id amount currency payment_intent].map { |key| read.call(key) }
      unless id.present? && amount.is_a?(Integer) && amount.positive? &&
          currency.to_s.downcase == payment.currency && (intent.nil? || intent == payment.provider_payment_id)
        raise RefundCreator::RefundError, "External refund details do not match the captured payment"
      end
      raise RefundCreator::RefundError, "Refund item ledger is missing" if payment.order.order_items.empty?

      # Serialize identity lookup and reservation: different callback IDs may
      # describe the same provider operation concurrently.
      Refund.transaction do
        payment.order.event.organization.lock!
        payment.order.event.lock!
        payment.order.lock!
        refund = payment.refunds.find_by(provider: "stripe", provider_refund_id: id)
        key = read.call(:metadata).to_h.stringify_keys["hafapass_refund_key"]
        refund ||= payment.refunds.find_by(idempotency_key: key) if key.present?
        if refund
          unless refund.amount_cents == amount && refund.currency == currency.to_s.downcase
            raise RefundCreator::RefundError, "External refund does not match the reserved operation"
          end
          return RefundCreator.reconcile_refund!(refund: refund, provider_refund: object)
        end
        raise RefundCreator::RefundError, "External refund key has no matching operation" if key.present?
        if payment.refunds.pending.where(provider_refund_id: nil).exists?
          raise RefundCreator::RefundError, "An unidentified local refund needs finance review"
        end

        RefundCreator.call(order: payment.order, payment: payment, amount_cents: amount,
          reason: "provider_webhook_reconciliation", idempotency_key: "provider:stripe:refund:#{id}",
          provider_refund: object)
      end
    end

    def self.call(issue:, call_budget: nil)
      payment = issue.payment
      raise RefundCreator::RefundError, "A captured Stripe payment is required" unless payment&.provider == "stripe"

      operations = StripeService.list_refunds(payment: payment, call_budget: call_budget)
      raise RefundCreator::RefundError, "Stripe returned no refund operations; keep this item open" if operations.empty?

      operations.each do |operation|
        unless operation.payment_intent == payment.provider_payment_id
          raise RefundCreator::RefundError, "Stripe returned a refund for another payment"
        end
        ingest!(payment: payment, provider_refund: operation)
      end
      # Keep the payout hold until all observed returned money is accounted for.
      booked = payment.refunds.succeeded.sum(:amount_cents)
      payment.reconciliation_exceptions.open.where(code: RECOVERABLE_CODES).find_each do |candidate|
        if candidate.code == "refund_aggregate_requires_reconciliation"
          next unless candidate.actual_amount_cents && candidate.actual_amount_cents <= booked
        else
          provider_id = candidate.webhook_event&.payload&.dig("data", "object", "id")
          next unless provider_id && payment.refunds.where(provider_refund_id: provider_id).exists?
        end

        candidate.resolve!
      end
      issue.reload
    end
  end
end
