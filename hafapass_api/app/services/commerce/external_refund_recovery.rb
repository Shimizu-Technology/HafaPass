# frozen_string_literal: true

require "ostruct"

module Commerce
  class ExternalRefundRecovery
    RECOVERABLE_CODES = %w[refund_operation_not_found refund_aggregate_requires_reconciliation].freeze
    FAILED_STATUSES = %w[failed canceled cancelled].freeze

    # Call only with a verified webhook's payment context or an authenticated
    # Stripe lookup scoped to the payment's immutable account/environment.
    def self.ingest!(payment:, provider_refund:)
      object = provider_refund
      id, amount, currency, intent = %i[id amount currency payment_intent].map { |key| value(object, key) }
      unless id.present? && amount.is_a?(Integer) && amount.positive? &&
          currency.to_s.downcase == payment.currency && (intent.nil? || intent == payment.provider_payment_id)
        raise RefundCreator::RefundError, "External refund details do not match the captured payment"
      end

      # Serialize identity lookup and reservation: different callback IDs may
      # describe the same provider operation concurrently.
      Refund.transaction do
        payment.order.event.organization.lock!
        payment.order.event.lock!
        payment.order.lock!
        refund = RefundCreator.find_provider_operation(payment: payment, provider_refund: object)
        if refund
          unless refund.amount_cents == amount && refund.currency == currency.to_s.downcase
            raise RefundCreator::RefundError, "External refund does not match the reserved operation"
          end
          return RefundCreator.reconcile_refund!(refund: refund, provider_refund: object)
        end
        # Terminal observations consume no current balance, but must retain
        # identity so an older success snapshot cannot create returned money.
        if FAILED_STATUSES.include?(value(object, :status))
          return record_historical_failure!(payment: payment, provider_refund: object)
        end
        raise RefundCreator::RefundError, "Refund item ledger is missing" if payment.order.order_items.empty?

        key = value(object, :metadata).to_h.stringify_keys["hafapass_refund_key"]
        if key.present? && !payment.refunds.exists?(idempotency_key: key)
          raise RefundCreator::RefundError, "External refund key has no matching operation"
        end
        if payment.refunds.pending.where(provider_refund_id: nil).exists?
          raise RefundCreator::RefundError, "An unidentified local refund needs finance review"
        end

        RefundCreator.call(order: payment.order, payment: payment, amount_cents: amount,
          reason: "provider_webhook_reconciliation", idempotency_key: "provider:stripe:refund:#{id}",
          provider_refund: object)
      end
    end

    def self.record_historical_failure!(payment:, provider_refund:)
      id, amount, currency, status = %i[id amount currency status].map { |key| value(provider_refund, key) }
      unless id.present? && amount.is_a?(Integer) && amount.positive? && currency == payment.currency && FAILED_STATUSES.include?(status)
        raise RefundCreator::RefundError, "Historical refund context is incomplete"
      end

      Refund.transaction do
        payment.order.event.organization.lock!
        payment.order.event.lock!
        payment.order.lock!
        existing = Refund.find_by(provider: "stripe", provider_refund_id: id)
        if existing
          raise RefundCreator::RefundError, "Historical refund belongs to another payment" unless existing.payment_id == payment.id

          return existing
        end
        refund = payment.refunds.create!(order: payment.order, provider: "stripe", provider_refund_id: id,
          idempotency_key: "provider:stripe:refund:#{id}", amount_cents: amount, currency: currency,
          status: status == "failed" ? :failed : :cancelled, failed_at: Time.current,
          reason: "provider_historical_observation", failure_code: "provider_#{status}",
          provider_payload: { historical_observation: true, status: status,
            provider_payment_id: payment.provider_payment_id, provider_environment: payment.provider_environment,
            provider_platform_account_id: payment.provider_platform_account_id, provider_account_id: payment.provider_account_id })
        AuditLogger.record!(action: "refund.external_observed", auditable: payment,
          event: payment.order.event, organization: payment.order.event.organization,
          source: "provider", outcome: "failed", deduplication_key: "external-refund:#{payment.id}:#{id}:#{status}",
          metadata: { provider_refund_id: id, provider_payment_id: payment.provider_payment_id,
            amount_cents: amount, currency: currency, status: status })
        refund
      end
    end

    # Earlier versions stored only an immutable provider audit. Restore its
    # terminal binding before any new observation of that provider identity.
    def self.restore_historical_identity!(payment:, provider_id:)
      observation = AuditLog.where(action: "refund.external_observed", auditable_type: "Payment")
        .where("metadata ->> 'provider_refund_id' = ?", provider_id).order(:id).first
      return unless observation
      unless observation.auditable_id == payment.id && observation.metadata["provider_payment_id"] == payment.provider_payment_id
        raise RefundCreator::RefundError, "Historical refund belongs to another payment"
      end
      object = observation.metadata
      record_historical_failure!(payment: payment, provider_refund: OpenStruct.new(id: provider_id,
        amount: object["amount_cents"], currency: object["currency"], status: object["status"]))
    end

    def self.call(issue:, call_budget: nil)
      payment = issue.payment
      raise RefundCreator::RefundError, "A captured Stripe payment is required" unless payment&.provider == "stripe"

      operations = StripeService.list_refunds(payment: payment, call_budget: call_budget)
      raise RefundCreator::RefundError, "Stripe returned no refund operations; keep this item open" if operations.empty?
      unless operations.all? { |operation| operation.payment_intent == payment.provider_payment_id }
        raise RefundCreator::RefundError, "Stripe returned a refund for another payment"
      end

      # Confirm existing reservations first, including failures that release
      # balance. Provider lists are newest-first, not reservation-order.
      known, external = operations.partition do |operation|
        RefundCreator.find_provider_operation(payment: payment, provider_refund: operation).present?
      end
      (known + external).each { |operation| ingest!(payment: payment, provider_refund: operation) }
      booked = payment.refunds.succeeded.sum(:amount_cents)
      payment.reconciliation_exceptions.open.where(code: RECOVERABLE_CODES).find_each do |candidate|
        if candidate.code == "refund_aggregate_requires_reconciliation"
          next unless candidate.actual_amount_cents && candidate.actual_amount_cents <= booked
        else
          observations = issue_observations(candidate, payment)
          next if observations.empty? || !observations.all? { |observation| reconciled_observation?(payment, observation, operations) }
        end

        candidate.resolve!
      end
      issue.reload
    end

    def self.issue_observations(issue, payment)
      if issue.details["provider_refund_id"].present?
        return [issue.details.slice("provider_refund_id", "provider_payment_id", "amount_cents", "currency", "status")]
      end

      # Legacy exceptions did not identify which embedded operation failed.
      # Validate every embedded observation before resolving that old issue.
      receipt = issue.webhook_event
      object = receipt&.payload&.dig("data", "object")
      return [] unless object && object["payment_intent"] == payment.provider_payment_id

      entries = if receipt.event_type == "charge.refunded"
        Array(object.dig("refunds", "data"))
      elsif %w[refund.created refund.updated refund.failed charge.refund.updated].include?(receipt.event_type)
        [object]
      else
        []
      end
      entries.map do |entry|
        { "provider_refund_id" => entry["id"], "provider_payment_id" => entry["payment_intent"] || object["payment_intent"],
          "amount_cents" => entry["amount"], "currency" => entry["currency"], "status" => entry["status"] }
      end
    end

    def self.reconciled_observation?(payment, observation, operations)
      id, intent, amount, currency, status = observation.values_at("provider_refund_id", "provider_payment_id", "amount_cents", "currency", "status")
      return false unless id.present? && intent == payment.provider_payment_id &&
        amount.is_a?(Integer) && amount.positive? && currency == payment.currency

      refund = payment.refunds.find_by(provider: "stripe", provider_refund_id: id, amount_cents: amount, currency: currency)
      return refund&.succeeded? if status == "succeeded"
      return refund.present? if %w[pending requires_action].include?(status)
      return false unless FAILED_STATUSES.include?(status)
      return false if refund && !(refund.failed? || refund.cancelled?)

      operations.any? do |operation|
        operation.id == id && operation.amount == amount && operation.currency == currency && FAILED_STATUSES.include?(operation.status)
      end
    end

    def self.value(object, key)
      object.respond_to?(key) ? object.public_send(key) : object[key.to_s] || object[key]
    end
    private_class_method :issue_observations, :reconciled_observation?, :value
  end
end
