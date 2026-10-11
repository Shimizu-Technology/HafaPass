# frozen_string_literal: true

require "digest"

class StripeProcessingFees
  class RetryableError < StandardError; end
  class EvidenceError < StandardError; end
  PENDING_CODE = "stripe_processing_fee_pending"
  REVIEW_CODE = "stripe_processing_fee_review_required"

  def self.external_capture?(payment)
    payment&.provider == "stripe" && payment.provider_environment != "simulate" && payment.provider_payment_id.present? &&
      !payment.provider_payment_id.start_with?("sim_") && payment.provider_payload.to_h["simulated"] != true &&
      (payment.succeeded? || payment.partially_refunded? || payment.refunded?)
  end

  def self.context_digest(payment)
    Digest::SHA256.hexdigest(JSON.generate([payment.provider_environment,
      payment.provider_platform_account_id, payment.provider_account_id]))
  end

  def self.missing_count(order_ids)
    Payment.where(order_id: order_ids, provider: "stripe", status: [:succeeded, :partially_refunded, :refunded])
      .where.not(provider_payment_id: nil).where("provider_payment_id NOT LIKE 'sim_%'")
      .where("provider_environment IS NULL OR provider_environment != 'simulate'")
      .where("COALESCE(provider_payload->>'simulated', 'false') != 'true'")
      .left_joins(:stripe_fee_evidence)
      .where("stripe_fee_evidences.status IS NULL OR stripe_fee_evidences.status != 'verified' OR " \
        "payments.provider_environment IS NULL OR payments.provider_platform_account_id IS NULL OR " \
        "stripe_fee_evidences.fee_component_id IS NULL").count
  end

  def self.request!(payment, recheck: false)
    return unless external_capture?(payment)

    evidence = StripeFeeEvidence.find_by(payment_id: payment.id) || StripeFeeEvidence.create!(payment: payment,
      context_digest: context_digest(payment), next_attempt_at: Time.current)
    if recheck || evidence.status_pending?
      ActiveRecord.after_all_transactions_commit do
        begin
          StripeProcessingFeeJob.perform_later(payment.id)
        rescue StandardError => e
          # A queue outage must not undo payment fulfillment. The persisted
          # pending row is retried by the sweep after queue recovery.
          begin
            evidence.reload.update!(last_error_code: "fee_queue_unavailable", next_attempt_at: Time.current) if evidence.status_pending?
          rescue ActiveRecord::ActiveRecordError
            # The already committed row remains due for the sweep.
          end
          Rails.logger.error({ event: "stripe_fee_enqueue_failed", payment_id: payment.id, error_class: e.class.name }.to_json)
        end
      end
    end
    evidence
  rescue ActiveRecord::RecordNotUnique
    payment.reload.stripe_fee_evidence
  end

  def self.require_adjustment_review!(payment, reference:)
    return unless external_capture?(payment)

    payment.order.with_lock do
      payment.reconciliation_exceptions.find_or_create_by!(order: payment.order,
        code: "stripe_fee_adjustment_review_required", details: { provider_reference: reference })
    end
  end

  def self.call(payment:)
    return unless external_capture?(payment)

    evidence = StripeFeeEvidence.find_by(payment_id: payment.id) || StripeFeeEvidence.create!(payment: payment, context_digest: context_digest(payment))
    raise EvidenceError, "provider_context_changed" unless evidence.context_digest == context_digest(payment)

    intent = StripeService.retrieve_fee_payment_intent(payment)
    facts = verified_facts(payment, intent)
    payment.order.event.organization.with_lock do
      payment.order.with_lock do
        payment.with_lock do
          evidence.with_lock do
            digest = Digest::SHA256.hexdigest(JSON.generate(facts))
            if evidence.evidence_digest && evidence.evidence_digest != digest
              raise EvidenceError, "provider_fee_evidence_changed"
            end
            unless evidence.fee_component
              if payment.order.fee_components.where(kind: "processing", estimated: false).exists?
                raise EvidenceError, "legacy_processing_cost_requires_mapping"
              end
              component = payment.order.fee_components.create!(kind: "processing", amount_cents: facts[:fee_cents],
                currency: facts[:currency], estimated: false, provider_reference: facts[:provider_balance_transaction_id],
                metadata: { provider: "stripe", payment_id: payment.id, context_digest: evidence.context_digest,
                  provider_charge_id: facts[:provider_charge_id], fee_details: facts[:fee_details] })
              evidence.fee_component = component
            end
            evidence.assign_attributes(facts)
            evidence.update!(status: :verified, evidence_digest: digest, verified_at: evidence.verified_at || Time.current,
              balance_status: value(value(intent, :latest_charge), :balance_transaction)&.then { |transaction| value(transaction, :status) },
              attempts: evidence.attempts + 1, next_attempt_at: nil, last_error_code: nil)
            payment.reconciliation_exceptions.open.where(code: PENDING_CODE).find_each(&:resolve!)
          end
        end
      end
    end
    evidence
  rescue RetryableError, Stripe::APIConnectionError, Stripe::RateLimitError, Stripe::APIError, IOError, Timeout::Error
    record_problem!(payment, evidence, retryable: true, code: "provider_fee_temporarily_unavailable")
    raise RetryableError, "Provider fee evidence is not available yet"
  rescue EvidenceError, StripeService::PaymentError, Stripe::StripeError => e
    record_problem!(payment, evidence, retryable: false, code: e.is_a?(EvidenceError) ? e.message : "provider_fee_context_unavailable")
    evidence
  rescue ActiveRecord::RecordNotUnique
    record_problem!(payment, evidence, retryable: false, code: "provider_fee_identity_conflict")
    evidence
  end

  def self.verified_facts(payment, intent)
    charge = value(intent, :latest_charge)
    unless value(intent, :id) == payment.provider_payment_id && value(intent, :status) == "succeeded" &&
        value(intent, :livemode) == (payment.provider_environment == "live") &&
        value(intent, :amount) == payment.amount_cents && value(intent, :amount_received) == payment.amount_cents && value(intent, :currency) == payment.currency
      raise EvidenceError, "provider_fee_payment_mismatch"
    end
    raise RetryableError, "charge_not_expanded" if charge.nil? || charge.is_a?(String)
    unless value(charge, :id).to_s.start_with?("ch_") && provider_id(value(charge, :payment_intent)) == payment.provider_payment_id &&
        value(charge, :paid) == true && value(charge, :captured) == true && value(charge, :status) == "succeeded" &&
        value(charge, :livemode) == (payment.provider_environment == "live") &&
        value(charge, :amount) == payment.amount_cents && value(charge, :amount_captured) == payment.amount_cents && value(charge, :currency) == payment.currency
      raise EvidenceError, "provider_fee_charge_mismatch"
    end
    transaction = value(charge, :balance_transaction)
    raise RetryableError, "balance_transaction_not_available" if transaction.nil? || transaction.is_a?(String)
    raw_details = value(transaction, :fee_details)
    raise EvidenceError, "provider_fee_breakdown_requires_review" unless raw_details.is_a?(Array)
    raise EvidenceError, "provider_fee_currency_conversion_requires_review" if value(transaction, :exchange_rate).present?

    details = raw_details.map do |detail|
      { amount: value(detail, :amount), currency: value(detail, :currency), type: value(detail, :type) }
    end
    details.sort_by! { |detail| [detail[:type].to_s, detail[:currency].to_s, detail[:amount].to_s] }
    amount, fee, net = [:amount, :fee, :net].map { |field| value(transaction, field) }
    unless value(transaction, :id).to_s.start_with?("txn_") && provider_id(value(transaction, :source)) == value(charge, :id) &&
        %w[pending available].include?(value(transaction, :status)) && value(transaction, :type) == "charge" && value(transaction, :currency) == payment.currency &&
        amount == payment.amount_cents && amount.is_a?(Integer) && fee.is_a?(Integer) && net.is_a?(Integer) &&
        fee >= 0 && fee <= amount && net == amount - fee
      raise EvidenceError, "provider_fee_balance_transaction_mismatch"
    end
    # Empty details can mean unavailable IC+ pricing data rather than zero cost.
    if details.empty? || !details.all? { |detail| detail[:amount].is_a?(Integer) && detail[:amount] >= 0 &&
        detail[:currency] == payment.currency && %w[stripe_fee payment_method_passthrough_fee].include?(detail[:type]) } ||
        details.sum { |detail| detail[:amount] } != fee
      raise EvidenceError, "provider_fee_breakdown_requires_review"
    end
    { provider_charge_id: value(charge, :id), provider_balance_transaction_id: value(transaction, :id),
      amount_cents: amount, fee_cents: fee, net_cents: net, currency: payment.currency, fee_details: details }
  end
  private_class_method :verified_facts

  def self.record_problem!(payment, evidence, retryable:, code:)
    return unless evidence

    payment.order.with_lock do
      evidence.with_lock do
        if evidence.status_verified? && (retryable || code == "provider_fee_context_unavailable")
          evidence.update!(attempts: evidence.attempts + 1, last_error_code: code)
          next
        end
        evidence.update!(status: retryable ? :pending : :review_required,
          attempts: evidence.attempts + 1, last_error_code: code, next_attempt_at: retryable ? 5.minutes.from_now : nil)
        payment.reconciliation_exceptions.find_or_create_by!(order: payment.order,
          code: retryable ? PENDING_CODE : REVIEW_CODE, status: :open)
      end
    end
  end
  private_class_method :record_problem!

  def self.value(object, key)
    return object.public_send(key) if object.respond_to?(key)
    object[key.to_s] if object.respond_to?(:[])
  end
  private_class_method :value

  def self.provider_id(object)
    object.is_a?(String) ? object : value(object, :id)
  end
  private_class_method :provider_id
end
