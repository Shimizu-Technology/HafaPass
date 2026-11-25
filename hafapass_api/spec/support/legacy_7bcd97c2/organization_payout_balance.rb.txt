# frozen_string_literal: true

class OrganizationPayoutBalance
  def self.available_cents(organization)
    return 0 if organization.payouts.exists?(failure_code: "provider_result_conflict")

    order_ids = Order.where(event_id: organization.events.select(:id)).select(:id)
    # Cash release requires every reconciliation item to be resolved, including
    # new/uncatalogued codes. RefundSafety's narrower list governs buyer refund
    # attempts; it is not the event closeout or organization payout policy.
    return 0 if ReconciliationException.open.where(order_id: order_ids).exists? ||
      ReconciliationException.open.joins(:payment).where(payments: { order_id: order_ids }).exists?

    return 0 if StripeProcessingFees.missing_count(order_ids).positive?

    latest_settlements = organization.settlements.status_finalized
      .select("DISTINCT ON (event_id) settlements.*")
      .order(:event_id, version: :desc)
    finalized = latest_settlements.to_a
    entitlement_cents = finalized.sum do |settlement|
      # Snapshots remain immutable. Current liabilities reduce their entitlement
      # immediately; new proceeds still require a newly approved settlement.
      current = Settlements::Calculator.call(settlement.event).attributes
      [net_entitlement(settlement.attributes.symbolize_keys), net_entitlement(current)].min
    end
    organization.events.where.not(id: finalized.map(&:event_id)).find_each do |event|
      entitlement_cents += [net_entitlement(Settlements::Calculator.call(event).attributes), 0].min
    end
    organization.events.cancelled.joins(:payouts).merge(Payout.status_paid).distinct.find_each do |event|
      recovery = RefundReconciliationQueue.recovery_amount_for_event(event)
      # Pending refunds and open disputes are deducted below for every event.
      # Only add the remaining recovery debit here to avoid reserving it twice.
      event_order_ids = event.orders.select(:id)
      already_reserved = Refund.pending.where(order_id: event_order_ids).sum(:amount_cents) +
        Dispute.open.where(order_id: event_order_ids).sum(:amount_cents)
      entitlement_cents -= [recovery - already_reserved, 0].max
    end
    organization_adjustments = organization.balance_adjustments.effective.where(event_id: nil).sum(:amount_cents)
    entitlement_cents += [organization_adjustments, 0].min
    unresolved_refunds = Refund.pending.where(order_id: order_ids).sum(:amount_cents)
    unresolved_disputes = Dispute.open.where(order_id: order_ids).sum(:amount_cents)
    committed_cents = organization.payouts.where(status: [:pending, :processing, :held, :paid]).sum(:amount_cents)
    [entitlement_cents - unresolved_refunds - unresolved_disputes - committed_cents, 0].max
  end

  def self.net_entitlement(attributes)
    attributes[:organizer_proceeds_cents] - attributes[:processing_fee_cents] -
      attributes[:reserve_cents] + attributes[:adjustment_cents]
  end
  private_class_method :net_entitlement
end
