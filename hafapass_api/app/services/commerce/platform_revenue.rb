# frozen_string_literal: true

require "set"

module Commerce
  # Platform-wide fee revenue for the admin dashboard, using the same rules as
  # Settlements::Calculator so the totals equal the sum of each event's
  # statement figures:
  # - gross platform fees are "platform" fee components less refunded fees,
  #   floored at zero per event;
  # - actual (non-estimated) card processing on an order whose bearer snapshot
  #   is "platform" is split by charged amount: HåfaPass covers the ticket share,
  #   the organizer the add-on/donation share;
  # - processing on "organizer" and legacy (NULL snapshot) orders stays with the
  #   organizer and never reduces platform revenue.
  # Each order's snapshot decides, never the live site setting.
  class PlatformRevenue
    SETTLED_STATUSES = %i[completed partially_refunded refunded].freeze

    def self.call(orders = Order.all)
      new(orders).call
    end

    def initialize(orders)
      @orders = orders.excluding_test_payments.where(status: SETTLED_STATUSES)
    end

    def call
      platform_processing, organizer_processing = processing_totals
      gross = gross_platform_fee_cents
      {
        gross_platform_fee_cents: gross,
        platform_processing_fee_cents: platform_processing,
        organizer_processing_fee_cents: organizer_processing,
        net_platform_revenue_cents: gross - platform_processing,
        orders_by_processing_bearer: orders.group(:processing_fee_bearer_snapshot).count
          .transform_keys { |bearer| bearer || "legacy" }
      }
    end

    private

    attr_reader :orders

    def order_ids
      orders.select(:id)
    end

    def gross_platform_fee_cents
      fees = FeeComponent.joins(:order).where(order_id: order_ids, kind: "platform")
        .group("orders.event_id").sum(:amount_cents)
      refunded = RefundItem.joins(refund: :order)
        .where(refunds: { order_id: order_ids, status: Refund.statuses[:succeeded] })
        .group("orders.event_id").sum(Arel.sql("refund_items.fee_cents + refund_items.organizer_fee_cents"))
      fees.keys.union(refunded.keys).sum { |event_id| [fees.fetch(event_id, 0) - refunded.fetch(event_id, 0), 0].max }
    end

    def processing_totals
      components = FeeComponent.joins(:order).where(order_id: order_ids, kind: "processing", estimated: false)
        .pluck(:id, :order_id, :amount_cents, "orders.processing_fee_bearer_snapshot")
      platform_order_ids = Set.new(components.select { |row| row[3] == "platform" }.map { |row| row[1] })
      charged = charged_by_line_kind(platform_order_ids)
      components.each_with_object([0, 0]) do |(_id, order_id, amount, bearer), totals|
        platform, organizer = bearer == "platform" ? platform_split(amount, charged.fetch(order_id, [0, 0])) : [0, amount]
        totals[0] += platform
        totals[1] += organizer
      end
    end

    # Mirrors Settlements::Calculator#processing_split.
    def platform_split(amount, (ticket_cents, other_cents))
      platform, organizer = MoneyAllocator.call(amount, [ticket_cents, other_cents])
      platform + organizer == amount ? [platform, organizer] : [amount, 0]
    end

    def charged_by_line_kind(order_ids)
      return {} if order_ids.empty?

      ticket_kind = OrderItem.item_kinds.fetch("ticket")
      sums = OrderItem.where(order_id: order_ids.to_a)
        .group(:order_id, Arel.sql("order_items.item_kind = #{ticket_kind}"))
        .sum(Arel.sql("order_items.subtotal_cents - order_items.discount_cents + order_items.fee_cents + order_items.tax_cents"))
      sums.each_with_object(Hash.new { |hash, key| hash[key] = [0, 0] }) do |((order_id, ticket), cents), result|
        result[order_id][ticket ? 0 : 1] += cents
      end
    end
  end
end
