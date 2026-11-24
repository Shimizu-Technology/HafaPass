# frozen_string_literal: true

# Monthly CPA custodial-liability and Guam BPT preparation report for one Guam
# calendar month (Pacific/Guam, UTC+10). Read-only preparation aid — not a
# filed tax return. Separates organizer proceeds held in custody (a balance
# sheet liability) from HåfaPass ticketing service-fee revenue (income).
#
# Reconciles to Settlements::Calculator (the payout statement service):
#   - Uses live/legacy USD Stripe captures (same agent-collection scope as
#     TaxReports#bpt_event_rows; excludes test/simulated, door cash, Clover).
#   - Uses Settlements::Calculator#processing_by_order for the exact platform vs
#     organizer Stripe processing-cost split.
#   - For any event with all activity on or before month end:
#       closing_custodial_liability_cents - ending_reserve_balance_cents ==
#         Settlements::Calculator balance_before_payout - paid_cents
#       ending_reserve_balance_cents == Settlements::Calculator reserve_cents
class CpaMonthlyReport
  GUAM_TIMEZONE = TaxReports::GUAM_TIMEZONE
  NOTE = "Preparation aid only — not a filed return. Ticket and event proceeds collected as limited agent are a custodial liability owed to organizers, separate from HåfaPass service-fee revenue. Estimated Guam BPT uses the statutory general rate under 11 GCA § 26202 on net HåfaPass fee revenue only (working position); confirm base, rate, any § 26203.2 small-business relief, and nonprofit DRT exemptions with your CPA."
  NONPROFIT_NOTE = "W-9 nonprofit; verify DRT exemption"

  HEADER = %w[
    row_type
    month
    organization_id
    event_id
    nonprofit_exempt_flag
    nonprofit_exemption_note
    opening_custodial_liability
    proceeds_collected
    proceeds_refunded
    chargebacks
    organizer_processing_deducted
    other_adjustments
    organizer_payouts_made
    closing_custodial_liability
    reserve_held
    reserve_released
    ending_reserve_balance
    backup_withholding_memo
    fee_revenue_gross
    fee_refunds
    fee_revenue_net
    stripe_processing_costs_informational
    bpt_base_fee_revenue_estimate
    estimated_bpt_rate_pct
    estimated_bpt_on_fee_revenue_estimate
    currency
  ].freeze

  MONEY_KEYS = %i[
    opening_custodial_liability_cents
    proceeds_collected_cents
    proceeds_refunded_cents
    chargebacks_cents
    organizer_processing_deducted_cents
    other_adjustments_cents
    organizer_payouts_made_cents
    closing_custodial_liability_cents
    reserve_held_cents
    reserve_released_cents
    ending_reserve_balance_cents
    backup_withholding_memo_cents
    fee_revenue_gross_cents
    fee_refunds_cents
    fee_revenue_net_cents
    stripe_processing_costs_cents
    bpt_base_fee_revenue_estimate_cents
    estimated_bpt_on_fee_revenue_estimate_cents
  ].freeze

  SUMMED_KEYS = (MONEY_KEYS - %i[estimated_bpt_on_fee_revenue_estimate_cents]).freeze

  attr_reader :year, :month

  def initialize(year, month)
    @year = Integer(year.to_s, 10)
    raise ArgumentError, "Choose a year from 2000 to 2100" unless (2000..2100).cover?(@year)

    @month = Integer(month.to_s, 10)
    raise ArgumentError, "Choose a month from 1 to 12" unless (1..12).cover?(@month)
  end

  def period
    format("%04d-%02d", year, month)
  end

  # Statutory general Guam BPT rate under 11 GCA § 26202 (basis points).
  # Estimate only; does not apply conditional § 26203.2 small-business relief.
  def bpt_rate_bps
    if year > 2026 || (year == 2026 && month >= 10)
      400
    elsif year > 2025 || (year == 2025 && month >= 10)
      450
    else
      500
    end
  end

  def bpt_rate_pct
    format("%.2f", bpt_rate_bps / 100.0)
  end

  def bpt_rate_note
    "#{bpt_rate_pct}% statutory general BPT estimate (11 GCA § 26202; excludes § 26203.2 small-business relief — confirm with CPA)"
  end

  def report
    @report ||= begin
      rows = build_rows
      totals = build_totals(rows)
      {
        year: year,
        month: month,
        period: period,
        timezone: GUAM_TIMEZONE,
        currency: "usd",
        bpt_rate_bps: bpt_rate_bps,
        bpt_rate_pct: bpt_rate_pct,
        bpt_rate_note: bpt_rate_note,
        note: NOTE,
        rows: rows,
        totals: totals
      }
    end
  end

  def organization_ids
    report[:rows].map { |row| row[:organization_id] }.uniq
  end

  def csv_rows
    data = report
    event_csv = data[:rows].map { |row| format_csv_row("event", row) }
    total_csv = format_csv_row("total", data[:totals])
    event_csv + [total_csv]
  end

  private

  def month_start
    @month_start ||= ActiveSupport::TimeZone[GUAM_TIMEZONE].local(year, month, 1)
  end

  def month_end
    @month_end ||= month_start.next_month
  end

  def agent_captures
    @agent_captures ||= Payment.live_or_legacy_capture.where(provider: "stripe", currency: "usd")
      .where("LEFT(COALESCE(provider_payment_id, ''), 4) <> 'sim_'")
      .where("provider_payload->>'simulated' IS DISTINCT FROM 'true' AND provider_payload->>'livemode' IS DISTINCT FROM 'false'")
  end

  def agent_orders
    @agent_orders ||= Order.excluding_test_payments
      .where(status: [:completed, :partially_refunded, :refunded], currency: "usd")
      .where(id: agent_captures.select(:order_id))
  end

  def orders_before
    @orders_before ||= agent_orders.where("COALESCE(orders.completed_at, orders.created_at) < ?", month_start)
  end

  def orders_in_month
    @orders_in_month ||= agent_orders.where(
      "COALESCE(orders.completed_at, orders.created_at) >= ? AND COALESCE(orders.completed_at, orders.created_at) < ?",
      month_start, month_end
    )
  end

  def agent_refunds
    @agent_refunds ||= begin
      base = Refund.succeeded.where(order_id: agent_orders.select(:id))
      base.where(payment_id: nil).or(base.where(payment_id: agent_captures.select(:id)))
    end
  end

  def refunds_before
    @refunds_before ||= agent_refunds.where("COALESCE(refunds.succeeded_at, refunds.created_at) < ?", month_start)
  end

  def refunds_in_month
    @refunds_in_month ||= agent_refunds.where(
      "COALESCE(refunds.succeeded_at, refunds.created_at) >= ? AND COALESCE(refunds.succeeded_at, refunds.created_at) < ?",
      month_start, month_end
    )
  end

  def lost_disputes_base
    @lost_disputes_base ||= Dispute.lost.where(order_id: agent_orders.select(:id), currency: "usd")
  end

  def disputes_before
    @disputes_before ||= lost_disputes_base.where("COALESCE(disputes.closed_at, disputes.updated_at) < ?", month_start)
  end

  def disputes_in_month
    @disputes_in_month ||= lost_disputes_base.where(
      "COALESCE(disputes.closed_at, disputes.updated_at) >= ? AND COALESCE(disputes.closed_at, disputes.updated_at) < ?",
      month_start, month_end
    )
  end

  def paid_payouts_base
    @paid_payouts_base ||= Payout.status_paid.where(currency: "usd", event_id: agent_orders.select(:event_id))
  end

  def payouts_before
    @payouts_before ||= paid_payouts_base.where("payouts.paid_at < ?", month_start)
  end

  def payouts_in_month
    @payouts_in_month ||= paid_payouts_base.where("payouts.paid_at >= ? AND payouts.paid_at < ?", month_start, month_end)
  end

  def adjustments_base(event_ids)
    BalanceAdjustment.where(status: [:posted, :reversed], currency: "usd", event_id: event_ids)
  end

  def build_rows
    proceeds_before = OrderItem.joins(:order).where(order_id: orders_before.select(:id))
      .group("orders.event_id").sum(:organizer_proceeds_cents)
    proceeds_month = OrderItem.joins(:order).where(order_id: orders_in_month.select(:id))
      .group("orders.event_id").sum(:organizer_proceeds_cents)

    refunded_proceeds_before = RefundItem.joins(refund: :order).where(refund_id: refunds_before.select(:id))
      .group("orders.event_id").sum("refund_items.organizer_proceeds_cents")
    refunded_proceeds_month = RefundItem.joins(refund: :order).where(refund_id: refunds_in_month.select(:id))
      .group("orders.event_id").sum("refund_items.organizer_proceeds_cents")

    chargebacks_before = disputes_before.joins(:order).group("orders.event_id").sum(:amount_cents)
    chargebacks_month = disputes_in_month.joins(:order).group("orders.event_id").sum(:amount_cents)

    payouts_gross_before = payouts_before.group(:event_id).sum(:amount_cents)
    payouts_gross_month = payouts_in_month.group(:event_id).sum(:amount_cents)
    withholding_month = payouts_in_month.group(:event_id).sum("withheld_cents + carried_withholding_cents")

    fee_gross_month = FeeComponent.joins(:order).where(order_id: orders_in_month.select(:id), kind: "platform")
      .group("orders.event_id").sum(:amount_cents)
    fee_refunds_month = RefundItem.joins(refund: :order).where(refund_id: refunds_in_month.select(:id))
      .group("orders.event_id").sum("refund_items.fee_cents + refund_items.organizer_fee_cents")

    candidate_event_ids = (
      proceeds_before.keys | proceeds_month.keys |
      refunded_proceeds_before.keys | refunded_proceeds_month.keys |
      chargebacks_before.keys | chargebacks_month.keys |
      payouts_gross_before.keys | payouts_gross_month.keys |
      fee_gross_month.keys | fee_refunds_month.keys
    )
    return [] if candidate_event_ids.empty?

    events = Event.where(id: candidate_event_ids).order(:organization_id, :id).to_a
    event_ids = events.map(&:id)
    org_ids = events.map(&:organization_id).uniq

    nonprofit_org_ids = OrganizerTaxInformation.where(organization_id: org_ids, tax_classification: "nonprofit")
      .pluck(:organization_id).to_set

    processing = processing_totals_by_event(events)
    adjustments = adjustment_totals_by_event(event_ids)

    event_rows = events.filter_map do |event|
      event_id = event.id
      org_id = event.organization_id
      proc_before_org, proc_month_org, proc_month_total = processing.fetch(event_id, [0, 0, 0])
      adj = adjustments.fetch(event_id, empty_adjustments)

      opening = proceeds_before.fetch(event_id, 0) -
        refunded_proceeds_before.fetch(event_id, 0) -
        chargebacks_before.fetch(event_id, 0) -
        proc_before_org +
        adj[:other_before] -
        payouts_gross_before.fetch(event_id, 0)

      collected = proceeds_month.fetch(event_id, 0)
      refunded = refunded_proceeds_month.fetch(event_id, 0)
      chargebacks = chargebacks_month.fetch(event_id, 0)
      other_adj = adj[:other_month]
      payouts_made = payouts_gross_month.fetch(event_id, 0)

      closing = opening + collected - refunded - chargebacks - proc_month_org + other_adj - payouts_made

      reserve_held = adj[:reserve_held_month]
      reserve_released = adj[:reserve_released_month]
      ending_reserve = [-adj[:reserve_net_through_month], 0].max

      fee_gross = fee_gross_month.fetch(event_id, 0)
      fee_refund = fee_refunds_month.fetch(event_id, 0)
      fee_net = fee_gross - fee_refund

      active_values = [
        opening, collected, refunded, chargebacks, proc_month_org, other_adj, payouts_made, closing,
        reserve_held, reserve_released, ending_reserve,
        fee_gross, fee_refund, proc_month_total
      ]
      next if active_values.all?(&:zero?)

      nonprofit = nonprofit_org_ids.include?(org_id)
      {
        organization_id: org_id,
        event_id: event_id,
        nonprofit_exempt_flag: nonprofit,
        nonprofit_exemption_note: nonprofit ? NONPROFIT_NOTE : "",
        opening_custodial_liability_cents: opening,
        proceeds_collected_cents: collected,
        proceeds_refunded_cents: refunded,
        chargebacks_cents: chargebacks,
        organizer_processing_deducted_cents: proc_month_org,
        other_adjustments_cents: other_adj,
        organizer_payouts_made_cents: payouts_made,
        closing_custodial_liability_cents: closing,
        reserve_held_cents: reserve_held,
        reserve_released_cents: reserve_released,
        ending_reserve_balance_cents: ending_reserve,
        backup_withholding_memo_cents: withholding_month.fetch(event_id, 0),
        fee_revenue_gross_cents: fee_gross,
        fee_refunds_cents: fee_refund,
        fee_revenue_net_cents: fee_net,
        stripe_processing_costs_cents: proc_month_total,
        bpt_base_fee_revenue_estimate_cents: fee_net,
        estimated_bpt_rate_pct: bpt_rate_pct,
        estimated_bpt_on_fee_revenue_estimate_cents: estimate_bpt_cents(fee_net)
      }
    end

    event_rows + org_level_adjustment_rows(org_ids, nonprofit_org_ids)
  end

  def processing_totals_by_event(events)
    before_ids_by_event = orders_before.pluck(:event_id, :id).group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
    month_ids_by_event = orders_in_month.pluck(:event_id, :id).group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
    events_with_processing = FeeComponent.joins(:order)
      .where(order_id: agent_orders.where("COALESCE(orders.completed_at, orders.created_at) < ?", month_end).select(:id),
        kind: "processing", estimated: false)
      .distinct.pluck("orders.event_id").to_set

    events.each_with_object({}) do |event, totals|
      next unless events_with_processing.include?(event.id)

      before_ids = before_ids_by_event.fetch(event.id, [])
      month_ids = month_ids_by_event.fetch(event.id, [])
      next if before_ids.empty? && month_ids.empty?

      split_by_order = Settlements::Calculator.new(event).processing_by_order
      org_before = before_ids.sum { |order_id| split_by_order.fetch(order_id, [0, 0]).last }
      org_month = month_ids.sum { |order_id| split_by_order.fetch(order_id, [0, 0]).last }
      total_month = month_ids.sum { |order_id| split_by_order.fetch(order_id, [0, 0]).sum }
      totals[event.id] = [org_before, org_month, total_month]
    end
  end

  def adjustment_totals_by_event(event_ids)
    records = adjustments_base(event_ids).where("effective_at < ?", month_end)
      .pluck(:event_id, :kind, :amount_cents, :effective_at)
    totals = Hash.new { |hash, key| hash[key] = empty_adjustments.dup }

    records.each do |event_id, kind, amount_cents, effective_at|
      bucket = totals[event_id]
      in_month = effective_at >= month_start
      if %w[reserve_hold reserve_release].include?(kind)
        bucket[:reserve_net_through_month] += amount_cents
        if in_month
          if kind == "reserve_hold"
            bucket[:reserve_held_month] -= amount_cents
          else
            bucket[:reserve_released_month] += amount_cents
          end
        end
      elsif in_month
        bucket[:other_month] += amount_cents
      else
        bucket[:other_before] += amount_cents
      end
    end
    totals
  end

  # Include organization-level (event_id: nil) balance adjustments so the CPA
  # custodial liability roll-forward matches OrganizationFinanceSummary.
  def org_level_adjustment_rows(org_ids, nonprofit_org_ids)
    records = BalanceAdjustment.where(status: [:posted, :reversed], currency: "usd", organization_id: org_ids, event_id: nil)
      .where("effective_at < ?", month_end)
      .pluck(:organization_id, :kind, :amount_cents, :effective_at)
    return [] if records.empty?

    by_org = Hash.new { |hash, key| hash[key] = empty_adjustments.dup }
    records.each do |org_id, kind, amount_cents, effective_at|
      bucket = by_org[org_id]
      in_month = effective_at >= month_start
      if %w[reserve_hold reserve_release].include?(kind)
        bucket[:reserve_net_through_month] += amount_cents
        if in_month
          if kind == "reserve_hold"
            bucket[:reserve_held_month] -= amount_cents
          else
            bucket[:reserve_released_month] += amount_cents
          end
        end
      elsif in_month
        bucket[:other_month] += amount_cents
      else
        bucket[:other_before] += amount_cents
      end
    end

    by_org.keys.sort.filter_map do |org_id|
      adj = by_org[org_id]
      opening = adj[:other_before]
      other_adj = adj[:other_month]
      closing = opening + other_adj
      reserve_held = adj[:reserve_held_month]
      reserve_released = adj[:reserve_released_month]
      ending_reserve = [-adj[:reserve_net_through_month], 0].max
      next if [opening, other_adj, closing, reserve_held, reserve_released, ending_reserve].all?(&:zero?)

      nonprofit = nonprofit_org_ids.include?(org_id)
      {
        organization_id: org_id,
        event_id: nil,
        nonprofit_exempt_flag: nonprofit,
        nonprofit_exemption_note: nonprofit ? NONPROFIT_NOTE : "",
        opening_custodial_liability_cents: opening,
        proceeds_collected_cents: 0,
        proceeds_refunded_cents: 0,
        chargebacks_cents: 0,
        organizer_processing_deducted_cents: 0,
        other_adjustments_cents: other_adj,
        organizer_payouts_made_cents: 0,
        closing_custodial_liability_cents: closing,
        reserve_held_cents: reserve_held,
        reserve_released_cents: reserve_released,
        ending_reserve_balance_cents: ending_reserve,
        backup_withholding_memo_cents: 0,
        fee_revenue_gross_cents: 0,
        fee_refunds_cents: 0,
        fee_revenue_net_cents: 0,
        stripe_processing_costs_cents: 0,
        bpt_base_fee_revenue_estimate_cents: 0,
        estimated_bpt_rate_pct: bpt_rate_pct,
        estimated_bpt_on_fee_revenue_estimate_cents: 0
      }
    end
  end

  def empty_adjustments
    { other_before: 0, other_month: 0, reserve_held_month: 0, reserve_released_month: 0, reserve_net_through_month: 0 }
  end

  def build_totals(rows)
    sums = SUMMED_KEYS.index_with { |key| rows.sum { |row| row.fetch(key, 0) } }
    nonprofit_count = rows.count { |row| row[:nonprofit_exempt_flag] }
    bpt_base = sums[:bpt_base_fee_revenue_estimate_cents]
    sums.merge(
      organization_id: nil,
      event_id: nil,
      nonprofit_exempt_flag: nil,
      nonprofit_event_count: nonprofit_count,
      nonprofit_exemption_note: "#{nonprofit_count} nonprofit-flagged row(s)",
      estimated_bpt_rate_pct: bpt_rate_pct,
      estimated_bpt_on_fee_revenue_estimate_cents: estimate_bpt_cents(bpt_base)
    )
  end

  def estimate_bpt_cents(base_cents)
    return 0 unless base_cents.positive?

    ((base_cents * bpt_rate_bps) + 5_000) / 10_000
  end

  def format_csv_row(row_type, row)
    flag = case row[:nonprofit_exempt_flag]
    when true then "yes"
    when false then "no"
    else ""
    end
    [
      row_type,
      period,
      row[:organization_id],
      row[:event_id],
      flag,
      row[:nonprofit_exemption_note].to_s,
      FinanceExports.money(row[:opening_custodial_liability_cents]),
      FinanceExports.money(row[:proceeds_collected_cents]),
      FinanceExports.money(row[:proceeds_refunded_cents]),
      FinanceExports.money(row[:chargebacks_cents]),
      FinanceExports.money(row[:organizer_processing_deducted_cents]),
      FinanceExports.money(row[:other_adjustments_cents]),
      FinanceExports.money(row[:organizer_payouts_made_cents]),
      FinanceExports.money(row[:closing_custodial_liability_cents]),
      FinanceExports.money(row[:reserve_held_cents]),
      FinanceExports.money(row[:reserve_released_cents]),
      FinanceExports.money(row[:ending_reserve_balance_cents]),
      FinanceExports.money(row[:backup_withholding_memo_cents]),
      FinanceExports.money(row[:fee_revenue_gross_cents]),
      FinanceExports.money(row[:fee_refunds_cents]),
      FinanceExports.money(row[:fee_revenue_net_cents]),
      FinanceExports.money(row[:stripe_processing_costs_cents]),
      FinanceExports.money(row[:bpt_base_fee_revenue_estimate_cents]),
      SpreadsheetExport::Amount.new(row[:estimated_bpt_rate_pct].to_s),
      FinanceExports.money(row[:estimated_bpt_on_fee_revenue_estimate_cents]),
      "USD"
    ]
  end
end
