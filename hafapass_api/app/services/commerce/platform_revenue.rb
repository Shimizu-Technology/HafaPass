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
  #
  # Classified (never-fulfilled) payments follow a separate rule (design
  # §8.2, A2), read from A1's rows like Commerce::ClassifiedPaymentFinance:
  # - fee revenue is the fee and organizer-fee share HåfaPass recognized at
  #   capture (K) less the share returned by recognized postings (P2 applied
  #   to lost disputes), never floored against organizer events;
  # - actual processing attributed to the classified payment is a platform
  #   cost under its snapshotted "platform" bearer, organizer processing
  #   under "organizer". Verified payment-scope facts with no fee component
  #   count as platform cost too, dated or not (this view has no period; the
  #   CPA projection books only dated ones and alerts the rest);
  # - their orders, refunds, refund items and components never enter the
  #   ordinary rule above, so payment B never changes A's figures.
  # Actual Stripe dispute fees are not recorded by any writer yet and appear
  # in no reader (§11).
  class PlatformRevenue
    SETTLED_STATUSES = %i[completed partially_refunded refunded].freeze

    def self.call(orders = Order.all)
      new(orders).call
    end

    def initialize(orders)
      @all_orders = orders.excluding_test_payments
      @orders = @all_orders.excluding_never_fulfilled.where(status: SETTLED_STATUSES)
    end

    def call
      platform_processing, organizer_processing = processing_totals
      classified = classified_totals
      gross = gross_platform_fee_cents + classified[:fee_revenue_cents]
      platform_processing += classified[:platform_processing_cents]
      organizer_processing += classified[:organizer_processing_cents]
      {
        gross_platform_fee_cents: gross,
        platform_processing_fee_cents: platform_processing,
        organizer_processing_fee_cents: organizer_processing,
        net_platform_revenue_cents: gross - platform_processing,
        orders_by_processing_bearer: orders.group(:processing_fee_bearer_snapshot).count
          .transform_keys { |bearer| bearer || "legacy" },
        classified: classified
      }
    end

    private

    attr_reader :orders, :all_orders

    def order_ids
      orders.select(:id)
    end

    def gross_platform_fee_cents
      fees = ClassifiedOrganizerView.organizer_fee_components(FeeComponent.joins(:order).where(order_id: order_ids, kind: "platform"))
        .group("orders.event_id").sum(:amount_cents)
      sale_refunds = Refund.succeeded.on_sale.where(order_id: order_ids)
      refunded = RefundItem.joins(refund: :order).where(refund_id: sale_refunds.select(:id))
        .group("orders.event_id").sum(Arel.sql("refund_items.fee_cents + refund_items.organizer_fee_cents"))
      fees.keys.union(refunded.keys).sum { |event_id| [fees.fetch(event_id, 0) - refunded.fetch(event_id, 0), 0].max }
    end

    def processing_totals
      components = ClassifiedOrganizerView.organizer_fee_components(
        FeeComponent.joins(:order).where(order_id: order_ids, kind: "processing", estimated: false)
      ).pluck(:id, :order_id, :amount_cents, "orders.processing_fee_bearer_snapshot")
      platform_order_ids = Set.new(components.select { |row| row[3] == "platform" }.map { |row| row[1] })
      charged = charged_by_line_kind(platform_order_ids)
      components.each_with_object([0, 0]) do |(_id, order_id, amount, bearer), totals|
        platform, organizer = bearer == "platform" ? platform_split(amount, charged.fetch(order_id, [0, 0])) : [0, amount]
        totals[0] += platform
        totals[1] += organizer
      end
    end

    def classified_captures
      @classified_captures ||= UnfulfilledCapture.where(order_id: all_orders.select(:id)).order(:id).to_a
    end

    # { fee_revenue_cents:, fee_returned_cents:, platform_processing_cents:,
    #   organizer_processing_cents:, excess_returned_cents: }
    def classified_totals
      captures = classified_captures
      zero = { fee_revenue_cents: 0, fee_returned_cents: 0, platform_processing_cents: 0,
        organizer_processing_cents: 0, excess_returned_cents: 0 }
      return zero if captures.empty?

      recognized = BuyerReturnPosting.recognized.where(never_fulfilled_capture_id: captures.map(&:id))
      fee_share = Arel.sql("buyer_return_postings.fee_cents + buyer_return_postings.organizer_fee_cents")
      returned = if NeverFulfilledCapture::LOST_DISPUTE_FEE_SHARE == :retained
        recognized.where(kind: %w[refund refund_reversal]).sum(fee_share)
      else
        recognized.sum(fee_share)
      end
      recognized_fee = captures.sum { |capture| capture.fee_cents + capture.organizer_fee_cents }
      by_order = captures.group_by(&:order_id)
      platform = 0
      organizer = 0
      ClassifiedPaymentFinance.attribute_processing(captures).each do |row|
        if ClassifiedOrganizerView.processing_bearer(row, by_order) == "organizer"
          organizer += row[:amount_cents]
        else
          platform += row[:amount_cents]
        end
      end
      platform += StripeFeeEvidence.where(fee_component_id: nil, last_error_code: StripeProcessingFees::PAYMENT_SCOPE_DEFERRED_CODE,
        payment_id: captures.select { |capture| capture.payment_scope? && capture.processing_bearer == "platform" }.map(&:payment_id))
        .where.not(evidence_digest: nil).sum(:fee_cents)
      zero.merge(fee_revenue_cents: recognized_fee - returned, fee_returned_cents: returned,
        platform_processing_cents: platform, organizer_processing_cents: organizer,
        excess_returned_cents: recognized.sum(:excess_cents))
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
