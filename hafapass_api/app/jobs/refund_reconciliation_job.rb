# frozen_string_literal: true

class RefundReconciliationJob < ApplicationJob
  queue_as :default

  def perform
    Refund.where(status: :pending, provider: "stripe").where("created_at <= ?", 1.hour.ago)
      .find_each do |refund|
      RefundReconciliationActions.call(type: "refund", id: refund.id, action: "resync",
        actor: nil, system: true)
    rescue RefundReconciliationActions::ActionError, Stripe::StripeError => e
      Rails.logger.warn("[RefundReconciliation] Refund #{refund.id} still needs review: #{e.class}")
    end

    items = RefundReconciliationQueue.new.entries
    flag_overdue!(items)
    EmailService.send_refund_reconciliation_digest_async(items, date: Date.current) if items.any?
  end

  private

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
