# frozen_string_literal: true

class RefundReconciliationJob < ApplicationJob
  queue_as :default
  DEFAULT_MAX_REFUNDS = 200
  DEFAULT_MAX_STRIPE_CALLS = 500
  DEFAULT_MAX_CONSECUTIVE_ERRORS = 5

  def perform
    max_refunds = positive_limit("REFUND_RECONCILIATION_MAX_REFUNDS", DEFAULT_MAX_REFUNDS)
    budget = StripeService::CallBudget.new(positive_limit("REFUND_RECONCILIATION_MAX_STRIPE_CALLS", DEFAULT_MAX_STRIPE_CALLS))
    max_errors = positive_limit("REFUND_RECONCILIATION_MAX_CONSECUTIVE_ERRORS", DEFAULT_MAX_CONSECUTIVE_ERRORS)
    attempted = 0
    errors = 0
    consecutive_errors = 0
    stop_reason = "completed"
    refunds = Refund.where(status: :pending, provider: "stripe").where("created_at <= ?", 1.hour.ago)
      .order(:created_at, :id).limit(max_refunds)
    refunds.each do |refund|
      begin
        RefundReconciliationActions.call(type: "refund", id: refund.id, action: "resync",
          actor: nil, system: true, stripe_call_budget: budget)
        attempted += 1
        consecutive_errors = 0
      rescue StripeService::BudgetExceeded
        stop_reason = "stripe_call_budget"
        break
      rescue Stripe::RateLimitError
        attempted += 1
        errors += 1
        stop_reason = "stripe_rate_limit"
        break
      rescue StripeService::AmbiguousRefund => e
        attempted += 1
        errors += 1
        consecutive_errors += 1
        last_flag = AuditLog.where(action: "refund_reconciliation.unable", auditable: refund).order(:id).last
        if last_flag&.metadata&.fetch("reason", nil) != e.message
          AuditLogger.record!(action: "refund_reconciliation.unable", auditable: refund,
            organization: refund.order.event.organization, metadata: { reason: e.message })
        end
        Rails.logger.warn("[RefundReconciliation] Refund #{refund.id} requires manual review: #{e.class}")
      rescue RefundReconciliationActions::ActionError, Stripe::StripeError => e
        attempted += 1
        errors += 1
        consecutive_errors += 1
        Rails.logger.warn("[RefundReconciliation] Refund #{refund.id} still needs review: #{e.class}")
      end
      if consecutive_errors >= max_errors
        stop_reason = "consecutive_errors"
        break
      end
    end
    Rails.logger.info("[RefundReconciliation] attempted=#{attempted} stripe_calls=#{budget.calls} errors=#{errors} stop=#{stop_reason}")

    items = RefundReconciliationQueue.new.entries
    flag_overdue!(items)
    EmailService.send_refund_reconciliation_digest_async(items, date: Date.current) if items.any?
  end

  private

  def positive_limit(name, default)
    value = Integer(ENV.fetch(name, default), exception: false)
    value&.positive? ? value : default
  end

  def flag_overdue!(items)
    types = RefundReconciliationActions::TYPES
    overdue = items.select { |item| item[:overdue] }
    return if overdue.empty?

    existing = AuditLog.where(action: "refund_reconciliation.overdue", auditable_type: types.values.map(&:name),
      auditable_id: overdue.map { |item| item[:id] }).pluck(:auditable_type, :auditable_id).to_set
    overdue.each do |item|
      model = types.fetch(item[:type])
      next if existing.include?([model.name, item[:id]])

      AuditLogger.record!(action: "refund_reconciliation.overdue", auditable: model.find(item[:id]),
        organization: Organization.find(item[:organization_id]), metadata: { age_seconds: item[:age_seconds] })
    end
  end
end
