# frozen_string_literal: true

module Commerce
  # Writes the durable classification of a captured payment HåfaPass did not
  # fulfil (docs/design/never-fulfilled-captures.md §4.3, A1 tranche 2).
  #
  # Runs only inside the lifecycle transaction that already holds the event
  # context, the order (FOR UPDATE) and the payment, in the documented order
  # (docs/LOCKING.md ranks 1-3). The insert trigger re-takes the order and the
  # payment it already holds, so this adds no lock and no network call.
  #
  # A row is written only from positive evidence: a real Stripe test or live
  # payment, captured with a database-recorded capture time, whose exact amount
  # and currency were reported by a signed webhook for that same PaymentIntent
  # or by an authenticated API lookup of it, and (order scope) whose order-item
  # components add up to the captured amount. Anything short of that is never
  # guessed: the payment is left unclassified and one
  # never_fulfilled_classification_quarantined exception records why.
  class NeverFulfilledClassification
    QUARANTINE_CODE = "never_fulfilled_classification_quarantined"
    OWNERSHIP_AMBIGUOUS_CODE = "never_fulfilled_ownership_ambiguous"
    SECOND_CAPTURE_CODE = "unfulfilled_second_capture"
    POLICY_VERSION = "nfc-v2.1"
    PROVIDER_ENVIRONMENTS = %w[test live].freeze
    CAPTURED_STATUSES = %w[succeeded partially_refunded refunded].freeze

    Result = Struct.new(:capture, :quarantine, keyword_init: true) do
      def classified?
        capture.present?
      end
    end

    # Only real Stripe captures are classified here. Simulated and other
    # providers (Clover is not live) keep their existing late-capture records.
    def self.applicable?(payment)
      payment.present? && payment.provider == "stripe" && PROVIDER_ENVIRONMENTS.include?(payment.provider_environment) &&
        payment.provider_payment_id.present? && !payment.provider_payment_id.start_with?("sim_") &&
        payment.provider_payload.to_h["simulated"] != true
    end

    # provider_evidence: what proved the capture, built by OrderLifecycle from
    # the signed webhook receipt or the API lookup that reported it.
    def self.classify!(order:, payment:, code:, provider_evidence:, capture_scope: "order", exception: nil,
      webhook_event: nil)
      new(order: order, payment: payment, code: code, provider_evidence: provider_evidence,
        capture_scope: capture_scope, exception: exception, webhook_event: webhook_event).classify!
    end

    def self.capture_for(payment)
      UnfulfilledCapture.find_by(payment_id: payment.id) if payment
    end

    def initialize(order:, payment:, code:, provider_evidence:, capture_scope:, exception:, webhook_event:)
      @order = order
      @payment = payment
      @code = code
      @provider_evidence = provider_evidence&.stringify_keys
      @capture_scope = capture_scope
      @exception = exception
      @webhook_event = webhook_event
    end

    def classify!
      raise ArgumentError, "classification must run inside the lifecycle transaction" unless Order.connection.transaction_open?
      raise ArgumentError, "unknown capture scope" unless UnfulfilledCapture::CAPTURE_SCOPES.include?(capture_scope)
      return Result.new unless self.class.applicable?(payment)

      # One classification per payment: a repeated notice returns the first.
      existing = self.class.capture_for(payment)
      return Result.new(capture: existing) if existing

      recorded_at = Payment.where(id: payment.id).pick(:capture_recorded_at)
      problem = identity_problem || capture_problem(recorded_at) || scope_problem
      return Result.new(quarantine: quarantine!(problem)) if problem

      components = order_scope? ? order_components : principal_components
      return Result.new(quarantine: quarantine!(components)) if components.is_a?(String)

      capture = UnfulfilledCapture.create!(
        order: order, payment: payment, capture_scope: capture_scope, code: code,
        captured_cents: payment.amount_cents, currency: payment.currency, **components,
        capture_recorded_at: recorded_at,
        processing_bearer: NeverFulfilledCapture.organizer_bears_processing? ? "organizer" : "platform",
        dispute_fee_bearer: NeverFulfilledCapture::DISPUTE_FEE_BEARER.to_s,
        allocation_policy: NeverFulfilledCapture::ALLOCATION_POLICY.to_s,
        policy_version: POLICY_VERSION, provenance: "lifecycle", provenance_evidence: evidence)
      AuditLogger.record!(action: "never_fulfilled_capture.classified", auditable: capture,
        organization: order.event.organization, event: order.event, outcome: "succeeded",
        deduplication_key: "unfulfilled_capture:#{capture.id}:classified",
        metadata: { order_id: order.id, payment_id: payment.id, capture_scope: capture_scope, code: code,
          captured_cents: capture.captured_cents, reconciliation_exception_id: exception&.id }.compact,
        **(webhook_event ? { source: "provider" } : {}))
      Result.new(capture: capture)
    end

    private

    attr_reader :order, :payment, :code, :provider_evidence, :capture_scope, :exception, :webhook_event

    def order_scope?
      capture_scope == "order"
    end

    # The provider fact must name this exact PaymentIntent with the exact
    # captured amount and currency.
    def identity_problem
      return "provider_evidence_missing" if provider_evidence.blank?

      amount = Integer(provider_evidence["amount_cents"].to_s, exception: false)
      currency = provider_evidence["currency"].to_s.downcase
      return "provider_amount_unverified" unless amount == payment.amount_cents && currency.present? && currency == payment.currency.to_s.downcase
      return "provider_identity_unverified" unless provider_evidence["provider_object_id"].to_s == payment.provider_payment_id

      case provider_evidence["source"]
      when "signed_webhook"
        event_type = provider_evidence["event_type"]
        "provider_identity_unverified" unless event_type == "payment_intent.succeeded" &&
          provider_evidence["webhook_event_id"].present?
      when "provider_lookup"
        "provider_identity_unverified" unless provider_evidence["livemode"] == (payment.provider_environment == "live")
      else
        "provider_evidence_missing"
      end
    end

    def capture_problem(recorded_at)
      return "payment_not_captured" unless CAPTURED_STATUSES.include?(payment.status)
      # A capture recorded before A1 needs backfill evidence (tranche 3), never a guess.
      "capture_recorded_before_a1" if recorded_at.nil?
    end

    def scope_problem
      if order_scope?
        return "order_amount_mismatch" unless payment.amount_cents == order.total_cents && payment.currency == order.currency
        return "order_fulfilled" if order.pending? || order.completed? || order.completed_at.present? ||
          order.fulfilled_by_payment_id.present? ||
          AuditLog.exists?(action: "order.completed", deduplication_key: "order:#{order.id}:completed")
        "active_tickets" if order.tickets.where.not(status: :cancelled).exists?
      else
        fulfilling = order.fulfilled_by_payment_id
        "fulfilling_payment_missing" if fulfilling.nil? || fulfilling == payment.id
      end
    end

    # Order-scope snapshot K (design §4.1): the order items' own components.
    # OrderCreator writes each line as proceeds = max(subtotal - discount -
    # organizer fee, 0), fee = buyer fee, organizer fee, tax 0, and the order
    # total as max(subtotal + buyer fees - discount, 0), so the components add
    # up to the total unless a line's discount plus organizer fee exceeds its
    # subtotal (the clamp). Such an order, or any other mismatch, is
    # quarantined rather than inserted.
    def order_components
      items = order.order_items.to_a
      return "components_missing" if items.empty?

      components = {
        proceeds_cents: items.sum(&:organizer_proceeds_cents), fee_cents: items.sum(&:fee_cents),
        organizer_fee_cents: items.sum(&:organizer_fee_cents), tax_cents: items.sum(&:tax_cents)
      }
      return "components_mismatch" unless components.values.sum == payment.amount_cents

      components
    end

    # A payment-scope capture bought nothing: the whole amount is buyer principal.
    def principal_components
      { proceeds_cents: payment.amount_cents, fee_cents: 0, organizer_fee_cents: 0, tax_cents: 0 }
    end

    def evidence
      release_audit = AuditLog.where(auditable: order, action: %w[order.expired order.cancelled]).order(:id).last if order_scope?
      provider_evidence.merge(
        "reconciliation_exception_id" => exception&.id,
        "release_audit_id" => release_audit&.id,
        "fulfilling_payment_id" => (order.fulfilled_by_payment_id unless order_scope?)
      ).compact
    end

    def quarantine!(reason)
      issue = ReconciliationException.find_by(payment: payment, code: QUARANTINE_CODE)
      issue || ReconciliationException.create!(order: order, payment: payment, webhook_event: webhook_event,
        code: QUARANTINE_CODE, details: { reason: reason, capture_scope: capture_scope, classification_code: code })
    end
  end
end
