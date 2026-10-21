# frozen_string_literal: true

# Cash-basis preparation aid, not a filed return. Dates are Guam calendar dates.
class TaxReports
  NOTE = "HåfaPass's gross receipts are its service fees; ticket proceeds belong to organizers (agent model). Confirm with your accountant."
  attr_reader :year

  def initialize(year)
    @year = Integer(year.to_s, 10)
    raise ArgumentError, "Choose a year from 2000 to 2100" unless (2000..2100).cover?(@year)
  end

  def as_json(*)
    { year: year, timezone: "Pacific/Guam", currency: "usd", organizers: organizers, months: months, note: NOTE }
  end

  def organizers
    @organizers ||= Organization.includes(:organizer_tax_information).order(:id).flat_map do |organization|
      event_ids = organization.events.select(:id)
      collected = collected_orders.where(event_id: event_ids)
      refunds = period_refunds.where(order_id: live_orders.where(event_id: event_ids).select(:id))
      payouts = paid_payouts.where(organization_id: organization.id).order(:id).to_a
      next [] unless collected.exists? || refunds.exists? || payouts.any?

      order_ids = collected.select(:id)
      refund_ids = refunds.select(:id)
      refund_lines = RefundItem.joins(:order_item).where(refund_id: refund_ids)
      activity = {
        gross_ticket_proceeds_cents: OrderItem.item_ticket.where(order_id: order_ids).sum("subtotal_cents - discount_cents"),
        gross_add_on_proceeds_cents: OrderItem.item_add_on.where(order_id: order_ids).sum("subtotal_cents - discount_cents"),
        gross_donation_proceeds_cents: OrderItem.item_donation.where(order_id: order_ids).sum("subtotal_cents - discount_cents"),
        gross_other_proceeds_cents: OrderItem.where(order_id: order_ids, item_kind: [:merchandise, :concession])
          .sum("subtotal_cents - discount_cents"),
        gross_non_ticket_proceeds_cents: OrderItem.where(order_id: order_ids).where.not(item_kind: :ticket)
          .sum("subtotal_cents - discount_cents"),
        ticket_refunds_cents: refund_lines.where(order_items: { item_kind: OrderItem.item_kinds[:ticket] })
          .sum("refund_items.amount_cents"),
        non_ticket_refunds_cents: refund_lines.where.not(order_items: { item_kind: OrderItem.item_kinds[:ticket] })
          .sum("refund_items.amount_cents"),
        unallocated_refunds_cents: refunds.sum(:amount_cents) - RefundItem.where(refund_id: refund_ids).sum(:amount_cents),
        fee_refunds_cents: refunded_fees(refunds),
        fees_collected_cents: fees(collected).sum(:amount_cents)
      }
      groups = payouts.group_by(&:tax_information_snapshot)
      groups = { nil => [] } if groups.empty?
      total_paid = payouts.sum(&:amount_cents)
      remainder = activity.dup
      groups.to_a.each_with_index.map do |(snapshot, group), index|
        paid = group.sum(&:amount_cents)
        share = if index == groups.length - 1
          remainder.dup
        else
          activity.transform_values { |amount| total_paid.positive? ? amount * paid / total_paid : 0 }
        end
        share.each { |key, amount| remainder[key] -= amount }
        tax = if snapshot.nil?
          organization.organizer_tax_information&.safe_json
        elsif snapshot.present?
          snapshot
        end
        adjustments = paid - share[:gross_ticket_proceeds_cents] - share[:gross_non_ticket_proceeds_cents] +
          share[:ticket_refunds_cents] + share[:non_ticket_refunds_cents] + share[:unallocated_refunds_cents] +
          share[:fees_collected_cents] -
          share[:fee_refunds_cents]
        { organization_id: organization.id, organization_name: organization.name,
          tax_snapshot_status: snapshot.nil? ? "No paid payout" : snapshot.blank? ? "No W-9 on file at payout" : "W-9 snapshotted at payout",
          tax_information: tax, w9_on_file: tax.present?, tax_snapshot_payout_id: group.first&.id,
          current_w9_on_file: organization.organizer_tax_information&.certified_at.present?,
          net_paid_cents: paid, refunds_cents: share[:ticket_refunds_cents] + share[:non_ticket_refunds_cents] +
            share[:unallocated_refunds_cents],
          fees_refunded_cents: share[:fee_refunds_cents], reconciliation_adjustments_cents: adjustments,
          **share }
      end
    end
  end

  def months
    (1..12).map do |month|
      range = month_start(month)...month_start(month).next_month
      collected = live_orders.where("COALESCE(orders.completed_at, orders.created_at) >= ? AND COALESCE(orders.completed_at, orders.created_at) < ?", range.begin, range.end)
      refunds = live_refunds.where("COALESCE(refunds.succeeded_at, refunds.created_at) >= ? AND COALESCE(refunds.succeeded_at, refunds.created_at) < ?", range.begin, range.end)
      collected_fees = fees(collected).sum(:amount_cents)
      returned_fees = refunded_fees(refunds)
      { month: month, fees_collected_cents: collected_fees, fees_refunded_cents: returned_fees,
        gross_receipts_cents: collected_fees - returned_fees,
        card_processing_costs_cents: FeeComponent.where(order_id: collected.select(:id), kind: "processing", estimated: false).sum(:amount_cents) }
    end
  end

  private

  def month_start(month)
    ActiveSupport::TimeZone["Pacific/Guam"].local(year, month, 1)
  end

  def period
    month_start(1)...month_start(1).next_year
  end

  def live_orders
    # The shared scope is production-only; enforce live evidence in every env.
    captured = Payment.where(provider_environment: "live", status: [:succeeded, :partially_refunded, :refunded])
    Order.excluding_test_payments.where(status: [:completed, :partially_refunded, :refunded], currency: "usd")
      .where(id: captured.select(:order_id))
  end

  def collected_orders
    live_orders.where("COALESCE(orders.completed_at, orders.created_at) >= ? AND COALESCE(orders.completed_at, orders.created_at) < ?", period.begin, period.end)
  end

  def live_refunds
    Refund.succeeded.where(order_id: live_orders.select(:id))
  end

  def period_refunds
    live_refunds.where("COALESCE(refunds.succeeded_at, refunds.created_at) >= ? AND COALESCE(refunds.succeeded_at, refunds.created_at) < ?", period.begin, period.end)
  end

  def paid_payouts
    Payout.status_paid.where(paid_at: period, currency: "usd", event_id: live_orders.select(:event_id))
  end

  def fees(orders)
    FeeComponent.where(order_id: orders.select(:id), kind: "platform")
  end

  def refunded_fees(refunds)
    RefundItem.where(refund_id: refunds.select(:id)).sum("fee_cents + organizer_fee_cents")
  end
end
