# frozen_string_literal: true

require "digest"

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
      processing_fees = processing_fee_components.sum(&:amount_cents)
      dispute_losses = lost_disputes.sum(&:amount_cents)
      reserve_effect = posted_adjustments.select { |adjustment| reserve_kind?(adjustment) }.sum(&:amount_cents)
      reserves = [-reserve_effect, 0].max
      adjustment_total = posted_adjustments.select { |adjustment| general_adjustment?(adjustment) }.sum(&:amount_cents)
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

    private

    attr_reader :event

    def orders
      @orders ||= event.orders.where(status: [:completed, :partially_refunded, :refunded]).order(:id).to_a
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

    def platform_fee_components
      @platform_fee_components ||= FeeComponent.where(order_id: order_ids, kind: "platform").order(:id).to_a
    end

    def processing_fee_components
      @processing_fee_components ||= FeeComponent.where(order_id: order_ids, kind: "processing", estimated: false).order(:id).to_a
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
        payout_items
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
