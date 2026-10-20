# frozen_string_literal: true

require "digest"
require "set"

module Settlements
  class Calculator
    Result = Data.define(:attributes, :items)

    def self.call(event)
      new(event).call
    end

    def initialize(event)
      @event = event
    end

    def call
      items = statement_items.sort_by { |item| [item[:occurred_at].to_f, item[:kind], item[:source_type], item[:source_id]] }
      gross = orders.sum(&:subtotal_cents)
      discounts = orders.sum(&:discount_cents)
      charged = orders.sum(&:total_cents)
      refunds = succeeded_refunds.sum(&:amount_cents)
      refunded_fees = refund_items.sum { |item| item.fee_cents + item.organizer_fee_cents }
      refunded_proceeds = refund_items.sum(&:organizer_proceeds_cents)
      platform_fees = [platform_fee_components.sum(&:amount_cents) - refunded_fees, 0].max
      organizer_proceeds = [order_items.sum(&:organizer_proceeds_cents) - refunded_proceeds, 0].max
      # Actual processing on an order whose bearer snapshot is "platform" is
      # split by charged amount: HåfaPass covers the ticket share (which earns
      # its fee) and the organizer bears the share for add-ons and donations.
      # Legacy (NULL) and "organizer" orders keep the full original deduction.
      processing_fees = processing_fee_components.sum { |component| processing_split(component).last }
      platform_processing_fees = processing_fee_components.sum { |component| processing_split(component).first }
      dispute_losses = lost_disputes.sum(&:amount_cents)
      reserve_effect = posted_adjustments.select { |adjustment| reserve_kind?(adjustment) }.sum(&:amount_cents)
      reserves = [-reserve_effect, 0].max
      adjustment_total = posted_adjustments.select { |adjustment| general_adjustment?(adjustment) }.sum(&:amount_cents)
      # Door cash stays with the organizer. It is earned revenue, but it is
      # not platform-held money available for a second payment to them.
      cash_retained = cash_proceeds - cash_refunded_proceeds
      adjustment_total -= cash_retained
      balance_before_payout = organizer_proceeds - processing_fees - dispute_losses - reserves + adjustment_total
      paid = event.payouts.status_paid.sum(:amount_cents)

      attributes = {
        organization: event.organization,
        event: event,
        currency: event.organization.currency,
        source_digest: source_digest(items),
        gross_cents: gross,
        discount_cents: discounts,
        refund_cents: refunds,
        net_cents: [charged - refunds, 0].max,
        platform_fee_cents: platform_fees,
        processing_fee_cents: processing_fees,
        platform_processing_fee_cents: platform_processing_fees,
        organizer_proceeds_cents: organizer_proceeds,
        reserve_cents: reserves,
        adjustment_cents: adjustment_total - dispute_losses,
        payable_cents: [balance_before_payout, 0].max,
        paid_cents: paid,
        negative_balance_cents: [paid - balance_before_payout, 0].max,
        calculated_at: Time.current
      }
      Result.new(attributes: attributes, items: items)
    end

    # Read-only per-order view of the same processing split, for organizer
    # exports: { order_id => [platform_cents, organizer_cents] }. It does not
    # feed the statement or its digest.
    def processing_by_order
      processing_fee_components.each_with_object(Hash.new { |hash, key| hash[key] = [0, 0] }) do |component, totals|
        platform, organizer = processing_split(component)
        totals[component.order_id][0] += platform
        totals[component.order_id][1] += organizer
      end
    end

    private

    attr_reader :event

    # Production settles real money only: orders paid through Stripe test (or
    # simulated) mode during QA never become organizer proceeds.
    def orders
      @orders ||= begin
        scope = event.orders.where(status: [:completed, :partially_refunded, :refunded])
        if Rails.env.production?
          scope = scope.where.not(id: Payment.where(provider: "stripe").where.not(provider_environment: "live")
            .select(:order_id))
        end
        scope.order(:id).to_a
      end
    end

    def order_ids
      @order_ids ||= orders.map(&:id)
    end

    def order_items
      @order_items ||= OrderItem.where(order_id: order_ids).order(:id).to_a
    end

    def succeeded_refunds
      @succeeded_refunds ||= Refund.succeeded.where(order_id: order_ids).order(:id).to_a
    end

    def refund_items
      @refund_items ||= RefundItem.where(refund_id: succeeded_refunds.map(&:id)).order(:id).to_a
    end

    def cash_order_ids
      # Payment.provider is immutable; a later edit to the order's display
      # method must not turn already-collected physical cash into a payable.
      @cash_order_ids ||= Set.new(orders.select { |order| order.payment_method == "door_cash" }.map(&:id) +
        Payment.where(order_id: order_ids, provider: "door_cash").pluck(:order_id))
    end

    def cash_proceeds
      order_items.select { |item| cash_order_ids.include?(item.order_id) }.sum(&:organizer_proceeds_cents)
    end

    def cash_refunded_proceeds
      refund_items.select { |item| cash_refund_item?(item) }.sum(&:organizer_proceeds_cents)
    end

    def cash_refund_item?(item)
      @refund_order_ids ||= succeeded_refunds.to_h { |refund| [refund.id, refund.order_id] }
      cash_order_ids.include?(@refund_order_ids.fetch(item.refund_id))
    end

    def platform_fee_components
      @platform_fee_components ||= FeeComponent.where(order_id: order_ids, kind: "platform").order(:id).to_a
    end

    def processing_fee_components
      @processing_fee_components ||= FeeComponent.where(order_id: order_ids, kind: "processing", estimated: false).order(:id).to_a
    end

    # Bearer comes only from each order's creation-time snapshot, never from
    # the live site setting, so a settings change cannot restate past orders.
    def platform_processing_order_ids
      @platform_processing_order_ids ||= Set.new(orders.select(&:platform_bears_processing?).map(&:id))
    end

    # [platform_cents, organizer_cents] for one actual processing cost. For a
    # platform-bearer order the cost is allocated pro rata by charged amount:
    # ticket lines (subtotal - discount + buyer fee + tax) to the platform,
    # catalog/add-on/donation lines to the organizer. Rounding cents fall on
    # the platform share. All of it stays with the organizer for other orders.
    def processing_split(component)
      @processing_splits ||= {}
      @processing_splits[component.id] ||= if platform_processing_order_ids.include?(component.order_id)
        ticket_cents, other_cents = charged_by_line_kind.fetch(component.order_id, [0, 0])
        platform, organizer = Commerce::MoneyAllocator.call(component.amount_cents, [ticket_cents, other_cents])
        platform + organizer == component.amount_cents ? [platform, organizer] : [component.amount_cents, 0]
      else
        [0, component.amount_cents]
      end
    end

    def charged_by_line_kind
      @charged_by_line_kind ||= order_items.group_by(&:order_id).transform_values do |items|
        charged = ->(item) { item.subtotal_cents - item.discount_cents + item.fee_cents + item.tax_cents }
        tickets, others = items.partition(&:item_ticket?)
        [tickets.sum(&charged), others.sum(&charged)]
      end
    end

    def lost_disputes
      @lost_disputes ||= Dispute.lost.where(order_id: order_ids).order(:id).to_a
    end

    def posted_adjustments
      @posted_adjustments ||= event.balance_adjustments.status_posted.where("effective_at <= ?", Time.current).order(:id).to_a
    end

    def reserve_kind?(adjustment)
      %w[reserve_hold reserve_release].include?(adjustment.kind)
    end

    def general_adjustment?(adjustment)
      !reserve_kind?(adjustment)
    end

    def statement_items
      sale_items + platform_fee_items + refund_statement_items + processing_items + dispute_items + adjustment_items +
        payout_items + cash_custody_items
    end

    def cash_custody_items
      sales = order_items.select { |item| cash_order_ids.include?(item.order_id) }.map do |item|
        statement_item(kind: "adjustment", amount_cents: -item.organizer_proceeds_cents, source: item,
          description: "Cash retained by organizer; excluded from platform payable", occurred_at: item.created_at,
          metadata: { order_id: item.order_id, adjustment_kind: "organizer_retained_cash", cash_custodian: "organizer" })
      end
      returns = refund_items.select { |item| cash_refund_item?(item) }.map do |item|
        statement_item(kind: "adjustment", amount_cents: item.organizer_proceeds_cents, source: item,
          description: "Cash returned by organizer; retained cash offset reduced",
          occurred_at: item.refund.succeeded_at || item.created_at,
          metadata: { refund_id: item.refund_id, adjustment_kind: "organizer_cash_return", cash_custodian: "organizer" })
      end
      sales + returns
    end

    def sale_items
      order_items.map do |item|
        statement_item(
          kind: "sale_proceeds",
          amount_cents: item.organizer_proceeds_cents,
          source: item,
          description: "#{item.quantity} × #{item.name}",
          occurred_at: item.created_at,
          metadata: { order_id: item.order_id, subtotal_cents: item.subtotal_cents, discount_cents: item.discount_cents }
        )
      end
    end

    def refund_statement_items
      refund_items.map do |item|
        statement_item(
          kind: "refund",
          amount_cents: -item.organizer_proceeds_cents,
          source: item,
          description: "Organizer proceeds refunded",
          occurred_at: item.refund.succeeded_at || item.created_at,
          metadata: { refund_id: item.refund_id, buyer_refund_cents: item.amount_cents,
            fee_refund_cents: item.fee_cents + item.organizer_fee_cents }
        )
      end
    end

    def platform_fee_items
      platform_fee_components.map do |component|
        statement_item(
          kind: "platform_fee",
          amount_cents: component.amount_cents,
          source: component,
          description: "Buyer-paid HafaPass service fee",
          occurred_at: component.created_at,
          metadata: { order_id: component.order_id, estimated: component.estimated? }
        )
      end
    end

    def processing_items
      processing_fee_components.map do |component|
        if platform_processing_order_ids.include?(component.order_id)
          platform_processing_item(component)
        else
          # Legacy wording and metadata are part of existing source digests.
          statement_item(
            kind: "processing_fee",
            amount_cents: -component.amount_cents,
            source: component,
            description: "Actual payment processing cost",
            occurred_at: component.updated_at,
            metadata: { order_id: component.order_id, provider_reference: component.provider_reference }
          )
        end
      end
    end

    # The statement binds the actual cost into its digest. Only the organizer
    # share (add-ons and donations) affects the organizer; the platform's fee
    # revenue absorbs the ticket share, even when it exceeds the fee collected.
    def platform_processing_item(component)
      platform_cents, organizer_cents = processing_split(component)
      statement_item(
        kind: "processing_fee",
        amount_cents: -organizer_cents,
        source: component,
        description: organizer_cents.zero? ? "Card processing covered by HåfaPass" :
          "Card processing on add-ons and donations; HåfaPass covers the ticket share",
        occurred_at: component.updated_at,
        metadata: { order_id: component.order_id, provider_reference: component.provider_reference,
          processing_fee_bearer: "platform", platform_cost_cents: platform_cents, organizer_cost_cents: organizer_cents }
      )
    end

    def dispute_items
      lost_disputes.map do |dispute|
        statement_item(
          kind: "dispute",
          amount_cents: -dispute.amount_cents,
          source: dispute,
          description: "Lost payment dispute",
          occurred_at: dispute.closed_at || dispute.updated_at,
          metadata: { order_id: dispute.order_id, provider_dispute_id: dispute.provider_dispute_id }
        )
      end
    end

    def adjustment_items
      posted_adjustments.map do |adjustment|
        statement_item(
          kind: reserve_kind?(adjustment) ? "reserve" : "adjustment",
          amount_cents: adjustment.amount_cents,
          source: adjustment,
          description: adjustment.reason,
          occurred_at: adjustment.effective_at,
          metadata: { adjustment_kind: adjustment.kind }
        )
      end
    end

    def payout_items
      event.payouts.where(status: [:pending, :processing, :paid, :reversed]).order(:id).map do |payout|
        statement_item(
          kind: "payout",
          amount_cents: payout.status_reversed? ? payout.amount_cents : -payout.amount_cents,
          source: payout,
          description: payout.status_reversed? ? "Payout reversed" : "Organizer payout",
          occurred_at: payout.paid_at || payout.initiated_at || payout.updated_at,
          metadata: { status: payout.status, provider: payout.provider, settlement_id: payout.settlement_id }
        )
      end
    end

    def statement_item(kind:, amount_cents:, source:, description:, occurred_at:, metadata: {})
      {
        kind: kind,
        amount_cents: amount_cents,
        currency: event.organization.currency,
        source_type: source.class.name,
        source_id: source.id,
        description: description,
        occurred_at: occurred_at,
        metadata: metadata
      }
    end

    def source_digest(items)
      canonical = items.map do |item|
        item.slice(:kind, :amount_cents, :currency, :source_type, :source_id, :description, :metadata)
      end
      Digest::SHA256.hexdigest(JSON.generate(canonical))
    end
  end
end
