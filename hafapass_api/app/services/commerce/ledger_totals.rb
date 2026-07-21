# frozen_string_literal: true

module Commerce
  class LedgerTotals
    def self.call(orders)
      new(orders).call
    end

    def initialize(orders)
      @orders = orders
    end

    def call
      settled_orders = orders.where(status: [:completed, :partially_refunded, :refunded])
      order_ids = settled_orders.select(:id)
      gross = settled_orders.sum(:subtotal_cents)
      discount = settled_orders.sum(:discount_cents)
      charged = settled_orders.sum(:total_cents)
      refunds = Refund.succeeded.where(order_id: order_ids).sum(:amount_cents)
      gross_fees = FeeComponent.where(order_id: order_ids).sum(:amount_cents)
      proceeds = OrderItem.where(order_id: order_ids).sum(:organizer_proceeds_cents)
      refund_allocations = RefundItem.joins(:refund)
        .where(refunds: { order_id: order_ids, status: Refund.statuses[:succeeded] })
      refunded_fees = refund_allocations.sum(:fee_cents) + refund_allocations.sum(:organizer_fee_cents)
      refunded_proceeds = refund_allocations.sum(:organizer_proceeds_cents)

      {
        gross_cents: gross,
        discount_cents: discount,
        refund_cents: refunds,
        net_cents: charged - refunds,
        fee_cents: [gross_fees - refunded_fees, 0].max,
        organizer_proceeds_cents: [proceeds - refunded_proceeds, 0].max,
        payout_ready_cents: [proceeds - refunded_proceeds, 0].max
      }
    end

    private

    attr_reader :orders
  end
end
