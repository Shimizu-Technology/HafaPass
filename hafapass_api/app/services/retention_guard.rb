# frozen_string_literal: true

# The last check before a retention write. Callers hold the row lock in the
# same transaction; this service deliberately does not cache associations.
class RetentionGuard
  REFERENCE_KEYS = %w[order_id order_ids order_reference order_references refund_id refund_ids
    payout_id payout_ids payment_id payment_ids ticket_id ticket_ids dispute_id dispute_ids
    ticket_transfer_id ticket_transfer_ids message_delivery_id message_delivery_ids
    transfer_id transfer_ids card_present_payment_attempt_id card_present_payment_attempt_ids
    provider_payout_id provider_dispute_id external_payment_id
    event_change_id event_change_ids settlement_id settlement_ids].freeze
  MONEY_PAYOUT_STATUSES = %w[pending processing held failed].freeze

  def self.protected?(record)
    return true if DataRetention.held?(record)
    return true if record.is_a?(Payout) && MONEY_PAYOUT_STATUSES.include?(record.status)

    references = references_in(record)
    orders = related_orders(record, references)
    return true if orders.any? { |order| DataRetention.held?(order) || unresolved_money?(order) }

    payout_ids = references.fetch("payout_id", []) + references.fetch("payout_ids", [])
    Payout.where(id: payout_ids).where(status: Payout.statuses.slice(*MONEY_PAYOUT_STATUSES).values).exists?
  end

  def self.protected_batch?(records)
    Array(records).to_h { |record| [record, protected?(record)] }
  end

  def self.related_orders(record, references = references_in(record))
    ids = %w[order_id order_ids].flat_map { |key| references.fetch(key, []) }
    refs = %w[order_reference order_references].flat_map { |key| references.fetch(key, []) }
    ids << record.id if record.is_a?(Order)
    ids << record.order_id if record.respond_to?(:order_id)
    ids << record.ticket&.order_id if record.respond_to?(:ticket)
    ids << record.payment&.order_id if record.respond_to?(:payment)
    ids << record.payment_event&.payment&.order_id if record.respond_to?(:payment_event)
    ids << record.order_item&.order_id if record.respond_to?(:order_item)
    ids.concat(Order.where(event_id: record.event_id).pluck(:id)) if record.is_a?(Payout)
    ids.concat(Order.where(event_id: record.event_id).pluck(:id)) if record.is_a?(FeeChangeNotice)
    if record.is_a?(FeeChange)
      ids.concat(Order.where(event_id: record.notices.select(:event_id)).pluck(:id))
    end
    if record.respond_to?(:message_delivery) && record.message_delivery
      ids.concat(related_orders(record.message_delivery).map(&:id))
    end
    if record.is_a?(AuditLog) && record.auditable
      ids.concat(related_orders(record.auditable).map(&:id))
    end
    if record.is_a?(WebhookEvent)
      ids.concat(PaymentEvent.where(webhook_event_id: record.id).joins(:payment).pluck("payments.order_id"))
    end
    ids.concat(Refund.where(id: references.fetch("refund_id", []) + references.fetch("refund_ids", [])).pluck(:order_id))
    ids.concat(Dispute.where(id: references.fetch("dispute_id", []) + references.fetch("dispute_ids", [])).pluck(:order_id))
    ids.concat(Payment.where(id: references.fetch("payment_id", []) + references.fetch("payment_ids", [])).pluck(:order_id))
    ids.concat(Ticket.where(id: references.fetch("ticket_id", []) + references.fetch("ticket_ids", [])).pluck(:order_id))
    ids.concat(TicketTransfer.where(id: references.fetch("ticket_transfer_id", []) +
      references.fetch("ticket_transfer_ids", []) + references.fetch("transfer_id", []) +
      references.fetch("transfer_ids", [])).joins(:ticket).pluck("tickets.order_id"))
    ids.concat(CardPresentPaymentAttempt.where(id: references.fetch("card_present_payment_attempt_id", []) +
      references.fetch("card_present_payment_attempt_ids", [])).pluck(:order_id))
    ids.concat(CardPresentPaymentAttempt.where(external_payment_id: references.fetch("external_payment_id", [])).pluck(:order_id))
    delivery_ids = references.fetch("message_delivery_id", []) + references.fetch("message_delivery_ids", [])
    MessageDelivery.where(id: delivery_ids).find_each { |delivery| ids.concat(related_orders(delivery).map(&:id)) }
    payouts = Payout.where(id: references.fetch("payout_id", []) + references.fetch("payout_ids", []))
      .or(Payout.where(provider_payout_id: references.fetch("provider_payout_id", [])))
    ids.concat(Order.where(event_id: payouts.select(:event_id)).pluck(:id))
    ids.concat(Dispute.where(provider_dispute_id: references.fetch("provider_dispute_id", [])).pluck(:order_id))
    event_ids = EventChange.where(id: references.fetch("event_change_id", []) +
      references.fetch("event_change_ids", [])).pluck(:event_id)
    event_ids.concat(Settlement.where(id: references.fetch("settlement_id", []) +
      references.fetch("settlement_ids", [])).pluck(:event_id))
    ids.concat(Order.where(event_id: event_ids).pluck(:id))
    Order.where(id: ids.compact).or(Order.where(reference: refs.compact)).includes(:event).distinct.to_a
  end

  def self.unresolved_money?(order)
    return true if order.refunds.pending.exists? || order.disputes.open.exists?
    return true if Payout.where(event_id: order.event_id, status: Payout.statuses.slice(*MONEY_PAYOUT_STATUSES).values).exists?
    return true if ReconciliationException.open.where(order_id: order.id).or(
      ReconciliationException.open.where(payment_id: order.payments.select(:id))).exists?
    return true if EventCancellationRefundItem.where(order_id: order.id,
      status: %w[pending failed needs_manual waiting_on_pending_refund waiting_on_dispute]).exists?
    return true if EventChangeResponse.where(order_id: order.id, decision: "refund_requested").exists?
    return true if RefundReconciliationQueue.new(event_id: order.event_id).entries.any? do |entry|
      entry[:order_id] == order.id
    end

    # Provider deliveries with an unknown outcome must be reconciled first.
    return true if MessageDelivery.where(order_id: order.id, provider_outcome_unknown: true).exists?
    pending = WebhookEvent.where(status: [:received, :processing])
    return true if pending.where(id: PaymentEvent.joins(:payment)
      .where(payments: { order_id: order.id }).select(:webhook_event_id)).exists?

    pending.find_each.any? do |receipt|
      related_orders(receipt).any? { |candidate| candidate.id == order.id }
    end
  end

  def self.references_in(record)
    found = Hash.new { |hash, key| hash[key] = [] }
    %w[metadata details payload before_data after_data outbound_payload provider_payload].each do |column|
      collect(record.public_send(column), found) if record.respond_to?(column)
    end
    if record.is_a?(WebhookEvent) && record.provider == "stripe"
      object = record.payload.dig("data", "object") || {}
      intent_id = record.event_type.to_s.start_with?("payment_intent.") ? object["id"] : object["payment_intent"]
      if intent_id.present?
        found["order_ids"].concat(Payment.where(provider: "stripe", provider_payment_id: intent_id)
          .pluck(:order_id))
        found["order_ids"].concat(Order.where(stripe_payment_intent_id: intent_id).pluck(:id))
      end
    end
    found
  end

  def self.collect(value, found)
    case value
    when Hash
      value.each do |key, item|
        name = key.to_s
        found[name].concat(Array(item)) if REFERENCE_KEYS.include?(name) && !item.is_a?(Hash)
        collect(item, found)
      end
    when Array then value.each { |item| collect(item, found) }
    end
    found
  end
  private_class_method :collect
end
