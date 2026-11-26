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
      # Classified (never-fulfilled) money is never a sale
      # (ClassifiedOrganizerView): order-scope orders are left out, and a
      # payment-scope capture's refunds and fees never touch its order's sale.
      settled_orders = orders.excluding_test_payments.excluding_never_fulfilled
        .where(status: [:completed, :partially_refunded, :refunded])
      order_ids = settled_orders.select(:id)
      gross = settled_orders.sum(:subtotal_cents)
      discount = settled_orders.sum(:discount_cents)
      charged = settled_orders.sum(:total_cents)
      sale_refunds = Refund.succeeded.on_sale.where(order_id: order_ids)
      refunds = sale_refunds.sum(:amount_cents)
      gross_fees = ClassifiedOrganizerView.organizer_fee_components(FeeComponent.where(order_id: order_ids)).sum(:amount_cents)
      proceeds = OrderItem.where(order_id: order_ids).sum(:organizer_proceeds_cents)
      refund_allocations = RefundItem.joins(:refund).where(refund_id: sale_refunds.select(:id))
      refunded_fees = refund_allocations.sum(:fee_cents) + refund_allocations.sum(:organizer_fee_cents)
      refunded_proceeds = refund_allocations.sum(:organizer_proceeds_cents)
      cash_order_ids = settled_orders.where(payment_method: "door_cash")
        .or(settled_orders.where(id: Payment.where(provider: "door_cash").select(:order_id))).select(:id)
      cash_proceeds = OrderItem.where(order_id: cash_order_ids).sum(:organizer_proceeds_cents)
      cash_refunds = refund_allocations.where(refunds: { order_id: cash_order_ids }).sum(:organizer_proceeds_cents)

      {
        gross_cents: gross,
        discount_cents: discount,
        refund_cents: refunds,
        net_cents: charged - refunds,
        fee_cents: [gross_fees - refunded_fees, 0].max,
        organizer_proceeds_cents: [proceeds - refunded_proceeds, 0].max,
        payout_ready_cents: [proceeds - refunded_proceeds - cash_proceeds + cash_refunds, 0].max
      }
    end

    private

    attr_reader :orders
  end
end
