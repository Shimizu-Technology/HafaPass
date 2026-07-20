# frozen_string_literal: true

class BackfillCommerceLedger < ActiveRecord::Migration[8.1]
  class LegacyOrder < ActiveRecord::Base
    self.table_name = "orders"
  end

  class LegacyTicket < ActiveRecord::Base
    self.table_name = "tickets"
  end

  class LegacyTicketType < ActiveRecord::Base
    self.table_name = "ticket_types"
  end

  class LegacyPricingTier < ActiveRecord::Base
    self.table_name = "pricing_tiers"
  end

  class LedgerItem < ActiveRecord::Base
    self.table_name = "order_items"
  end

  class LedgerFee < ActiveRecord::Base
    self.table_name = "fee_components"
  end

  class LedgerHold < ActiveRecord::Base
    self.table_name = "inventory_holds"
  end

  class LedgerPayment < ActiveRecord::Base
    self.table_name = "payments"
  end

  class LedgerRefund < ActiveRecord::Base
    self.table_name = "refunds"
  end

  class LedgerRefundItem < ActiveRecord::Base
    self.table_name = "refund_items"
  end

  class LedgerPromoRedemption < ActiveRecord::Base
    self.table_name = "promo_redemptions"
  end

  def up
    LegacyOrder.find_each do |order|
      backfill_order(order)
    end
  end

  def down
    # The structural migration owns rollback. Ledger rows intentionally have no
    # destructive standalone rollback because they may have become authoritative.
  end

  private

  def backfill_order(order)
    items = backfill_items(order)
    backfill_fee(order)
    payment = backfill_payment(order)
    backfill_refund(order, payment, items)
    backfill_promo(order)
  end

  def backfill_items(order)
    tickets = LegacyTicket.where(order_id: order.id).order(:id).to_a
    groups = tickets.group_by { |ticket| [ticket.ticket_type_id, ticket.pricing_tier_id] }
    return [] if groups.empty?

    subtotals = groups.map do |(ticket_type_id, pricing_tier_id), grouped_tickets|
      ticket_type = LegacyTicketType.find(ticket_type_id)
      tier = LegacyPricingTier.find_by(id: pricing_tier_id)
      unit_price = tier&.price_cents || ticket_type.price_cents
      unit_price.to_i * grouped_tickets.length
    end
    discounts = allocate(order.discount_cents.to_i, subtotals)
    fees = allocate(order.service_fee_cents.to_i, subtotals)

    groups.each_with_index.map do |((ticket_type_id, pricing_tier_id), grouped_tickets), index|
      ticket_type = LegacyTicketType.find(ticket_type_id)
      tier = LegacyPricingTier.find_by(id: pricing_tier_id)
      unit_price = tier&.price_cents || ticket_type.price_cents
      item = LedgerItem.create!(
        order_id: order.id,
        ticket_type_id: ticket_type_id,
        pricing_tier_id: pricing_tier_id,
        name: ticket_type.name,
        tier_name: tier&.name,
        unit_price_cents: unit_price.to_i,
        quantity: grouped_tickets.length,
        subtotal_cents: subtotals[index],
        discount_cents: discounts[index],
        fee_cents: fees[index],
        tax_cents: 0,
        organizer_proceeds_cents: [subtotals[index] - discounts[index], 0].max,
        currency: order.currency,
        created_at: order.created_at,
        updated_at: order.updated_at
      )
      LegacyTicket.where(id: grouped_tickets.map(&:id)).update_all(order_item_id: item.id)
      backfill_pending_hold(order, item, ticket_type, tier)
      item
    end
  end

  def backfill_pending_hold(order, item, ticket_type, tier)
    return unless order.status == 0

    expires_at = 10.minutes.from_now
    LedgerHold.create!(
      order_id: order.id,
      order_item_id: item.id,
      event_id: order.event_id,
      ticket_type_id: ticket_type.id,
      pricing_tier_id: tier&.id,
      quantity: item.quantity,
      status: 0,
      expires_at: expires_at,
      created_at: order.created_at,
      updated_at: Time.current
    )
    LegacyTicketType.where(id: ticket_type.id).update_all(
      "quantity_sold = GREATEST(quantity_sold - #{item.quantity.to_i}, 0)"
    )
    if tier
      LegacyPricingTier.where(id: tier.id).update_all(
        "quantity_sold = GREATEST(quantity_sold - #{item.quantity.to_i}, 0)"
      )
    end
    LegacyOrder.where(id: order.id).update_all(expires_at: expires_at)
  end

  def backfill_fee(order)
    LedgerFee.create!(
      order_id: order.id,
      kind: "platform",
      amount_cents: order.service_fee_cents.to_i,
      currency: order.currency,
      estimated: true,
      metadata: { backfilled: true },
      created_at: order.created_at,
      updated_at: order.updated_at
    )
  end

  def backfill_payment(order)
    return if order.stripe_payment_intent_id.blank?

    LedgerPayment.create!(
      order_id: order.id,
      provider: "stripe",
      provider_payment_id: order.stripe_payment_intent_id,
      idempotency_key: "legacy:order:#{order.id}",
      amount_cents: order.total_cents,
      currency: order.currency,
      status: payment_status(order),
      succeeded_at: order.completed_at,
      failed_at: order.cancelled_at,
      provider_payload: { backfilled: true },
      created_at: order.created_at,
      updated_at: order.updated_at
    )
  end

  def backfill_refund(order, payment, items)
    return unless order.refund_amount_cents.to_i.positive?

    refund = LedgerRefund.create!(
      order_id: order.id,
      payment_id: payment&.id,
      provider: "stripe",
      provider_refund_id: order.stripe_refund_id,
      idempotency_key: "legacy:refund:order:#{order.id}",
      amount_cents: order.refund_amount_cents,
      currency: order.currency,
      status: 1,
      reason: order.refund_reason,
      succeeded_at: order.refunded_at || order.updated_at,
      provider_payload: { backfilled: true },
      created_at: order.refunded_at || order.updated_at,
      updated_at: order.updated_at
    )
    allocations = allocate(order.refund_amount_cents, items.map { |item| item.subtotal_cents + item.fee_cents - item.discount_cents })
    items.each_with_index do |item, index|
      next if allocations[index].zero?

      LedgerRefundItem.create!(
        refund_id: refund.id,
        order_item_id: item.id,
        amount_cents: allocations[index],
        quantity: 0,
        created_at: refund.created_at,
        updated_at: refund.updated_at
      )
    end
  end

  def backfill_promo(order)
    return if order.promo_code_id.blank? || order.discount_cents.to_i.zero?

    finalized = [1, 2, 4].include?(order.status)
    LedgerPromoRedemption.create!(
      promo_code_id: order.promo_code_id,
      order_id: order.id,
      status: finalized ? 1 : (order.status == 0 ? 0 : 2),
      discount_cents: order.discount_cents,
      expires_at: order.expires_at,
      finalized_at: finalized ? (order.completed_at || order.updated_at) : nil,
      released_at: finalized || order.status == 0 ? nil : order.updated_at,
      created_at: order.created_at,
      updated_at: order.updated_at
    )
  end

  def payment_status(order)
    return 5 if order.status == 2
    return 4 if order.status == 4
    return 1 if [1, 2, 4].include?(order.status)
    return 2 if order.status == 3

    0
  end

  def allocate(total, weights)
    return Array.new(weights.length, 0) if total.zero? || weights.empty? || weights.sum.zero?

    result = weights.map { |weight| (total * weight).div(weights.sum) }
    (total - result.sum).times { |index| result[index % result.length] += 1 }
    result
  end
end
