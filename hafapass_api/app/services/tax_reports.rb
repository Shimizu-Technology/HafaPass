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
    @organizers ||= Organization.includes(:organizer_tax_information).order(:id).filter_map do |organization|
      event_ids = organization.events.select(:id)
      collected = collected_orders.where(event_id: event_ids)
      refunds = period_refunds.where(order_id: live_orders.where(event_id: event_ids).select(:id))
      paid = paid_payouts.where(organization_id: organization.id).sum(:amount_cents)
      next unless collected.exists? || refunds.exists? || paid.positive?

      tax = organization.organizer_tax_information
      { organization_id: organization.id, organization_name: organization.name,
        gross_ticket_proceeds_cents: OrderItem.item_ticket.where(order_id: collected.select(:id))
          .sum("subtotal_cents - discount_cents"),
        refunds_cents: refunds.sum(:amount_cents),
        fees_collected_cents: fees(collected).sum(:amount_cents),
        fees_refunded_cents: refunded_fees(refunds),
        net_paid_cents: paid, tax_information: tax&.safe_json, w9_on_file: tax&.certified_at.present? }
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
    nonlive_stripe = Payment.where(provider: "stripe").where("provider_environment IS NULL OR provider_environment != ?", "live")
    Order.excluding_test_payments.where(status: [:completed, :partially_refunded, :refunded], currency: "usd")
      .where(id: captured.select(:order_id)).where.not(id: nonlive_stripe.select(:order_id))
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
