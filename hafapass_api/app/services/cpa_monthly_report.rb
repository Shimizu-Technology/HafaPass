# frozen_string_literal: true

# Monthly CPA custodial-liability and Guam BPT preparation report for one Guam
# calendar month (Pacific/Guam, UTC+10). Read-only preparation aid — not a
# filed tax return. Separates organizer proceeds held in custody (a balance
# sheet liability) from HåfaPass ticketing service-fee revenue (income).
#
# Period-stability guarantee:
#   - Movements are dated by ledger/occurrence timestamp, never current mutable
#     status, so a closed month does not change when later activity happens:
#     * Payouts paid in Month M stay in Month M (`paid_at`), even if reversed
#       in Month M+1; the reversal appears in Month M+1 (`payout_reversals`)
#       using the reversal confirmation timestamp from `payout.reconciled`
#       audit evidence (fallback: `payouts.updated_at`).
#     * Actual Stripe processing fees (`FeeComponent` kind: "processing",
#       estimated: false) are attributed to the month evidence is recorded
#       (`COALESCE(stripe_fee_evidences.verified_at, fee_components.created_at)`).
#   - Balance sheet totals compute custodial payables and organizer deficits
#     per organization (offsetting only within the same organization_id, never
#     netting unrelated organizers).
#   - Reconciles to Settlements::Calculator via `non_custodial_settlement_bridge`
#     (e.g. organizer-direct Clover sales included in settlement but not held in
#     HåfaPass Stripe custody) and flags any unallocated legacy refunds.
class CpaMonthlyReport
  GUAM_TIMEZONE = TaxReports::GUAM_TIMEZONE
  NOTE = "Preparation aid only — not a filed return. Under our working position for CPA and counsel review, ticket and event proceeds collected as limited agent are a custodial liability owed to organizers, separate from HåfaPass service-fee revenue. Estimated Guam BPT applies the statutory 11 GCA § 26202(c) service-business rate (P.L. 38-136) to net HåfaPass fee revenue only; confirm base, rate, any § 26203.2 small-business relief, and external DRT nonprofit exemptions with your CPA."
  NONPROFIT_NOTE = "W-9 nonprofit; DRT exemption not tracked — verify externally"
  DRT_VERIFIED_STATUS = "not_tracked"

  HEADER = %w[
    row_type
    month
    organization_id
    event_id
    w9_nonprofit_classification
    drt_exemption_verified
    nonprofit_exemption_note
    opening_custodial_liability
    proceeds_collected
    proceeds_refunded
    chargebacks
    organizer_processing_deducted
    other_adjustments
    organizer_payouts_made
    payout_reversals
    closing_custodial_liability
    closing_custodial_payables
    closing_organizer_deficits
    reserve_held
    reserve_released
    ending_reserve_balance
    unallocated_refunds_exception
    reconciliation_exception_flag
    non_custodial_settlement_bridge
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

  SUMMED_KEYS = %i[
    opening_custodial_liability_cents
    proceeds_collected_cents
    proceeds_refunded_cents
    chargebacks_cents
    organizer_processing_deducted_cents
    other_adjustments_cents
    organizer_payouts_made_cents
    payout_reversals_cents
    closing_custodial_liability_cents
    reserve_held_cents
    reserve_released_cents
    ending_reserve_balance_cents
    unallocated_refunds_exception_cents
    non_custodial_settlement_bridge_cents
    backup_withholding_memo_cents
    fee_revenue_gross_cents
    fee_refunds_cents
    fee_revenue_net_cents
    stripe_processing_costs_cents
    bpt_base_fee_revenue_estimate_cents
  ].freeze

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

  # Statutory 11 GCA § 26202(c) service-business Guam BPT rate (basis points)
  # per Public Law 38-136 (4.5% from Oct 1, 2025; 4.0% from Oct 1, 2026; 5.0%
  # prior statutory general rate). Estimate only; excludes § 26203.2 relief.
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
    if year > 2025 || (year == 2025 && month >= 10)
      "#{bpt_rate_pct}% statutory § 26202(c) service-business BPT estimate (P.L. 38-136; excludes § 26203.2 small-business relief — confirm with CPA)"
    else
      "#{bpt_rate_pct}% pre-P.L. 38-136 historical BPT estimate (prior 11 GCA § 26202; confirm applicable rate with CPA)"
    end
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

  # Lazy enumerator so SpreadsheetExport#stream_csv streams rows without
  # buffering all formatted CSV arrays in memory.
  def csv_rows
    data = report
    Enumerator.new do |yielder|
      data[:rows].each { |row| yielder << format_csv_row("event", row) }
      yielder << format_csv_row("total", data[:totals])
    end
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

  # Scope disputes by disputes.payment_id -> live Stripe capture (with legacy
  # payment_id NULL fallback restricted to provider: "stripe" on agent orders).
  def lost_disputes_base
    @lost_disputes_base ||= begin
      base = Dispute.lost.where(order_id: agent_orders.select(:id), provider: "stripe", currency: "usd")
      base.where(payment_id: nil).or(base.where(payment_id: agent_captures.select(:id)))
    end
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

  # Period-stable payouts: any payout that was paid (paid_at present, status
  # paid or later reversed) remains recorded in its paid_at month.
  def ever_paid_payouts_base
    @ever_paid_payouts_base ||= Payout.where(status: [:paid, :reversed], currency: "usd", event_id: agent_orders.select(:event_id))
      .where.not(paid_at: nil)
  end

  def payouts_paid_before
    @payouts_paid_before ||= ever_paid_payouts_base.where("payouts.paid_at < ?", month_start)
  end

  def payouts_paid_in_month
    @payouts_paid_in_month ||= ever_paid_payouts_base.where("payouts.paid_at >= ? AND payouts.paid_at < ?", month_start, month_end)
  end

  # Reversal movements are dated by the reversal confirmation timestamp from
  # `payout.reconciled` audit evidence (falling back to audit occurred_at or
  # payouts.updated_at), so reversing a prior-month payout never rewrites the
  # closed paid month.
  def payout_reversals_by_event
    reversal_audit_join = <<~SQL.squish
      LEFT JOIN LATERAL (
        SELECT occurred_at, metadata
        FROM audit_logs
        WHERE audit_logs.auditable_type = 'Payout'
          AND audit_logs.auditable_id = payouts.id
          AND audit_logs.action = 'payout.reconciled'
          AND audit_logs.after_data->>'status' = 'reversed'
        ORDER BY audit_logs.id DESC
        LIMIT 1
      ) rev_audit ON true
    SQL

    reversed_at_expr = <<~SQL.squish
      COALESCE(
        CASE
          WHEN rev_audit.metadata->'reconciliation'->>'confirmed_at' ~ '^\\d{4}-\\d{2}-\\d{2}T'
          THEN (rev_audit.metadata->'reconciliation'->>'confirmed_at')::timestamptz
        END,
        rev_audit.occurred_at,
        payouts.updated_at
      )
    SQL

    scope = Payout.status_reversed.where(currency: "usd", event_id: agent_orders.select(:event_id))
      .where.not(paid_at: nil)
      .joins(reversal_audit_join)
      .where("#{reversed_at_expr} < ?", month_end)

    before_amounts = Hash.new(0)
    month_amounts = Hash.new(0)
    month_withholding = Hash.new(0)

    scope.group("payouts.event_id", Arel.sql("#{reversed_at_expr} >= #{ActiveRecord::Base.connection.quote(month_start)}"))
      .pluck(
        "payouts.event_id",
        Arel.sql("#{reversed_at_expr} >= #{ActiveRecord::Base.connection.quote(month_start)}"),
        Arel.sql("SUM(payouts.amount_cents)"),
        Arel.sql("SUM(payouts.withheld_cents + payouts.carried_withholding_cents)")
      ).each do |event_id, in_month, amount_sum, withheld_sum|
        if in_month
          month_amounts[event_id] += amount_sum.to_i
          month_withholding[event_id] += withheld_sum.to_i
        else
          before_amounts[event_id] += amount_sum.to_i
        end
      end

    [before_amounts, month_amounts, month_withholding]
  end

  # All posted/reversed USD balance adjustments through month_end, excluding
  # only those explicitly attached to a non-agent order or non-agent dispute.
  def in_scope_adjustments
    @in_scope_adjustments ||= BalanceAdjustment.where(status: [:posted, :reversed], currency: "usd")
      .where("effective_at < ?", month_end)
      .where("order_id IS NULL OR order_id IN (#{agent_orders.select(:id).to_sql})")
      .where("dispute_id IS NULL OR dispute_id IN (#{lost_disputes_base.select(:id).to_sql})")
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

    refunds_total_before = refunds_before.joins(:order).group("orders.event_id").sum(:amount_cents)
    refunds_total_month = refunds_in_month.joins(:order).group("orders.event_id").sum(:amount_cents)
    allocated_before = RefundItem.joins(refund: :order).where(refund_id: refunds_before.select(:id))
      .group("orders.event_id").sum("refund_items.amount_cents")
    allocated_month = RefundItem.joins(refund: :order).where(refund_id: refunds_in_month.select(:id))
      .group("orders.event_id").sum("refund_items.amount_cents")

    chargebacks_before = disputes_before.joins(:order).group("orders.event_id").sum(:amount_cents)
    chargebacks_month = disputes_in_month.joins(:order).group("orders.event_id").sum(:amount_cents)

    payouts_gross_before = payouts_paid_before.group(:event_id).sum(:amount_cents)
    payouts_gross_month = payouts_paid_in_month.group(:event_id).sum(:amount_cents)
    withholding_paid_month = payouts_paid_in_month.group(:event_id).sum("withheld_cents + carried_withholding_cents")
    reversals_before, reversals_month, withholding_reversed_month = payout_reversals_by_event

    fee_gross_month = FeeComponent.joins(:order).where(order_id: orders_in_month.select(:id), kind: "platform")
      .group("orders.event_id").sum(:amount_cents)
    fee_refunds_month = RefundItem.joins(refund: :order).where(refund_id: refunds_in_month.select(:id))
      .group("orders.event_id").sum("refund_items.fee_cents + refund_items.organizer_fee_cents")

    processing = processing_totals_by_event_sql
    event_adjustments, org_adjustments = adjustment_totals_sql

    candidate_event_ids = (
      proceeds_before.keys | proceeds_month.keys |
      refunded_proceeds_before.keys | refunded_proceeds_month.keys |
      refunds_total_before.keys | refunds_total_month.keys |
      chargebacks_before.keys | chargebacks_month.keys |
      payouts_gross_before.keys | payouts_gross_month.keys |
      reversals_before.keys | reversals_month.keys |
      fee_gross_month.keys | fee_refunds_month.keys |
      processing.keys | event_adjustments.keys
    )

    events = candidate_event_ids.empty? ? [] : Event.where(id: candidate_event_ids).order(:organization_id, :id).to_a
    event_ids = events.map(&:id)
    all_org_ids = (events.map(&:organization_id) | org_adjustments.keys).uniq
    return [] if all_org_ids.empty?

    nonprofit_org_ids = OrganizerTaxInformation.where(organization_id: all_org_ids, tax_classification: "nonprofit")
      .pluck(:organization_id).to_set

    settlement_bridge_by_event = non_custodial_settlement_bridge_by_event(event_ids)

    event_rows = events.filter_map do |event|
      event_id = event.id
      org_id = event.organization_id
      proc_before_org, proc_month_org, proc_month_total = processing.fetch(event_id, [0, 0, 0])
      adj = event_adjustments.fetch(event_id, empty_adjustments)

      opening = proceeds_before.fetch(event_id, 0) -
        refunded_proceeds_before.fetch(event_id, 0) -
        chargebacks_before.fetch(event_id, 0) -
        proc_before_org +
        adj[:other_before] -
        payouts_gross_before.fetch(event_id, 0) +
        reversals_before.fetch(event_id, 0)

      collected = proceeds_month.fetch(event_id, 0)
      refunded = refunded_proceeds_month.fetch(event_id, 0)
      chargebacks = chargebacks_month.fetch(event_id, 0)
      other_adj = adj[:other_month]
      payouts_made = payouts_gross_month.fetch(event_id, 0)
      payout_rev = reversals_month.fetch(event_id, 0)

      closing = opening + collected - refunded - chargebacks - proc_month_org + other_adj - payouts_made + payout_rev

      reserve_held = adj[:reserve_held_month]
      reserve_released = adj[:reserve_released_month]
      ending_reserve = [-adj[:reserve_net_through_month], 0].max

      unalloc_before = refunds_total_before.fetch(event_id, 0) - allocated_before.fetch(event_id, 0)
      unalloc_month = refunds_total_month.fetch(event_id, 0) - allocated_month.fetch(event_id, 0)
      unalloc_cumulative = unalloc_before + unalloc_month
      has_exception = !unalloc_month.zero? || !unalloc_cumulative.zero?

      bridge_cents = settlement_bridge_by_event.fetch(event_id, 0)

      fee_gross = fee_gross_month.fetch(event_id, 0)
      fee_refund = fee_refunds_month.fetch(event_id, 0)
      fee_net = fee_gross - fee_refund

      active_values = [
        opening, collected, refunded, chargebacks, proc_month_org, other_adj,
        payouts_made, payout_rev, closing,
        reserve_held, reserve_released, ending_reserve,
        unalloc_month, unalloc_cumulative, bridge_cents,
        fee_gross, fee_refund, proc_month_total
      ]
      next if active_values.all?(&:zero?)

      w9_nonprofit = nonprofit_org_ids.include?(org_id)
      {
        organization_id: org_id,
        event_id: event_id,
        w9_nonprofit_classification: w9_nonprofit,
        drt_exemption_verified: DRT_VERIFIED_STATUS,
        nonprofit_exemption_note: w9_nonprofit ? NONPROFIT_NOTE : "",
        opening_custodial_liability_cents: opening,
        proceeds_collected_cents: collected,
        proceeds_refunded_cents: refunded,
        chargebacks_cents: chargebacks,
        organizer_processing_deducted_cents: proc_month_org,
        other_adjustments_cents: other_adj,
        organizer_payouts_made_cents: payouts_made,
        payout_reversals_cents: payout_rev,
        closing_custodial_liability_cents: closing,
        closing_custodial_payables_cents: [closing, 0].max,
        closing_organizer_deficits_cents: [-closing, 0].max,
        reserve_held_cents: reserve_held,
        reserve_released_cents: reserve_released,
        ending_reserve_balance_cents: ending_reserve,
        unallocated_refunds_exception_cents: unalloc_month,
        cumulative_unallocated_refunds_exception_cents: unalloc_cumulative,
        reconciliation_exception_flag: has_exception,
        non_custodial_settlement_bridge_cents: bridge_cents,
        backup_withholding_memo_cents: withholding_paid_month.fetch(event_id, 0) - withholding_reversed_month.fetch(event_id, 0),
        fee_revenue_gross_cents: fee_gross,
        fee_refunds_cents: fee_refund,
        fee_revenue_net_cents: fee_net,
        stripe_processing_costs_cents: proc_month_total,
        bpt_base_fee_revenue_estimate_cents: fee_net,
        estimated_bpt_rate_pct: bpt_rate_pct,
        estimated_bpt_on_fee_revenue_estimate_cents: estimate_bpt_cents(fee_net)
      }
    end

    (event_rows + org_level_adjustment_rows(org_adjustments, nonprofit_org_ids))
      .sort_by { |row| [row[:organization_id], row[:event_id] || Float::INFINITY] }
  end

  # SQL-aggregated processing costs, period-dated by when Stripe fee evidence
  # was verified/recorded (`COALESCE(stripe_fee_evidences.verified_at, fee_components.created_at)`).
  # Splits platform vs organizer share identically to Settlements::Calculator#processing_split:
  #   - Non-platform bearer (organizer / legacy nil): 100% organizer (pure SQL)
  #   - Platform bearer, ticket-only order: 100% platform (pure SQL)
  #   - Platform bearer, mixed ticket + add-on/donation order: pro-rata via Commerce::MoneyAllocator
  def processing_totals_by_event_sql
    recorded_at_expr = "COALESCE(stripe_fee_evidences.verified_at, fee_components.created_at)"
    quoted_start = ActiveRecord::Base.connection.quote(month_start)
    in_month_expr = "#{recorded_at_expr} >= #{quoted_start}"

    base = FeeComponent.joins(:order)
      .joins("LEFT JOIN stripe_fee_evidences ON stripe_fee_evidences.fee_component_id = fee_components.id AND stripe_fee_evidences.status = 'verified'")
      .where(order_id: agent_orders.select(:id), kind: "processing", estimated: false)
      .where("#{recorded_at_expr} < ?", month_end)

    totals = Hash.new { |hash, key| hash[key] = [0, 0, 0] }

    # 1. Organizer-borne or legacy NULL bearer: 100% organizer
    base.where("orders.processing_fee_bearer_snapshot IS DISTINCT FROM 'platform'")
      .group("orders.event_id", Arel.sql(in_month_expr))
      .pluck("orders.event_id", Arel.sql(in_month_expr), Arel.sql("SUM(fee_components.amount_cents)"))
      .each do |event_id, in_month, amount|
        cents = amount.to_i
        if in_month
          totals[event_id][1] += cents
          totals[event_id][2] += cents
        else
          totals[event_id][0] += cents
        end
      end

    # 2. Platform-borne, ticket-only orders: 100% platform (0% organizer)
    ticket_kind = OrderItem.item_kinds.fetch("ticket")
    base.where(orders: { processing_fee_bearer_snapshot: "platform" })
      .where("NOT EXISTS (SELECT 1 FROM order_items oi WHERE oi.order_id = orders.id AND oi.item_kind <> ?)", ticket_kind)
      .where("#{recorded_at_expr} >= ?", month_start)
      .group("orders.event_id")
      .sum("fee_components.amount_cents")
      .each do |event_id, amount|
        totals[event_id][2] += amount.to_i
      end

    # 3. Platform-borne, mixed ticket + non-ticket orders: exact MoneyAllocator pro-rata split
    split_join_sql = ActiveRecord::Base.sanitize_sql_array([
      <<~SQL.squish,
        INNER JOIN (
          SELECT order_id,
            SUM(CASE WHEN item_kind = ? THEN subtotal_cents - discount_cents + fee_cents + tax_cents ELSE 0 END) AS ticket_charged,
            SUM(CASE WHEN item_kind <> ? THEN subtotal_cents - discount_cents + fee_cents + tax_cents ELSE 0 END) AS other_charged
          FROM order_items
          GROUP BY order_id
        ) oi_split ON oi_split.order_id = orders.id
      SQL
      ticket_kind,
      ticket_kind
    ])

    mixed_rows = base.where(orders: { processing_fee_bearer_snapshot: "platform" })
      .where("EXISTS (SELECT 1 FROM order_items oi WHERE oi.order_id = orders.id AND oi.item_kind <> ?)", ticket_kind)
      .joins(split_join_sql)
      .pluck(
        "orders.event_id",
        Arel.sql(in_month_expr),
        "fee_components.amount_cents",
        Arel.sql("oi_split.ticket_charged"),
        Arel.sql("oi_split.other_charged")
      )

    mixed_rows.each do |event_id, in_month, amount_cents, ticket_charged, other_charged|
      amount = amount_cents.to_i
      platform, organizer = Commerce::MoneyAllocator.call(amount, [ticket_charged.to_i, other_charged.to_i])
      platform, organizer = [amount, 0] unless platform + organizer == amount
      if in_month
        totals[event_id][1] += organizer
        totals[event_id][2] += amount
      else
        totals[event_id][0] += organizer
      end
    end

    totals
  end

  def adjustment_totals_sql
    event_totals = Hash.new { |hash, key| hash[key] = empty_adjustments.dup }
    org_totals = Hash.new { |hash, key| hash[key] = empty_adjustments.dup }

    quoted_start = ActiveRecord::Base.connection.quote(month_start)
    in_month_expr = "effective_at >= #{quoted_start}"

    in_scope_adjustments
      .group(:organization_id, :event_id, :kind, Arel.sql(in_month_expr))
      .pluck(:organization_id, :event_id, :kind, Arel.sql(in_month_expr), Arel.sql("SUM(amount_cents)"))
      .each do |org_id, event_id, kind, in_month, sum_cents|
        amount = sum_cents.to_i
        bucket = event_id ? event_totals[event_id] : org_totals[org_id]
        if %w[reserve_hold reserve_release].include?(kind)
          bucket[:reserve_net_through_month] += amount
          if in_month
            if kind == "reserve_hold"
              bucket[:reserve_held_month] -= amount
            else
              bucket[:reserve_released_month] += amount
            end
          end
        elsif in_month
          bucket[:other_month] += amount
        else
          bucket[:other_before] += amount
        end
      end

    [event_totals, org_totals]
  end

  # Bridges custodial Stripe closing liability to Settlements::Calculator by
  # quantifying net settlement-only proceeds on non-custodial non-cash payments
  # (e.g. organizer-direct Clover card-present sales) and any non-agent lost
  # disputes that appear in Settlements::Calculator but not HåfaPass custody.
  def non_custodial_settlement_bridge_by_event(event_ids)
    return {} if event_ids.empty?

    cash_order_ids = Order.where(event_id: event_ids, payment_method: "door_cash")
      .or(Order.where(event_id: event_ids, id: Payment.where(provider: "door_cash").select(:order_id)))
      .select(:id)

    non_custodial_orders = Order.excluding_test_payments
      .where(event_id: event_ids, status: [:completed, :partially_refunded, :refunded], currency: "usd")
      .where("COALESCE(orders.completed_at, orders.created_at) < ?", month_end)
      .where.not(id: agent_orders.select(:id))
      .where.not(id: cash_order_ids)

    bridge = Hash.new(0)
    OrderItem.joins(:order).where(order_id: non_custodial_orders.select(:id))
      .group("orders.event_id").sum(:organizer_proceeds_cents)
      .each { |event_id, cents| bridge[event_id] += cents }

    RefundItem.joins(refund: :order)
      .where(refunds: { status: Refund.statuses[:succeeded], order_id: non_custodial_orders.select(:id) })
      .where("COALESCE(refunds.succeeded_at, refunds.created_at) < ?", month_end)
      .group("orders.event_id").sum("refund_items.organizer_proceeds_cents")
      .each { |event_id, cents| bridge[event_id] -= cents }

    # Non-custodial lost disputes: lost disputes on non-custodial orders, plus
    # any lost disputes on agent orders whose payment_id is NOT a live Stripe capture.
    all_event_orders = Order.excluding_test_payments
      .where(event_id: event_ids, status: [:completed, :partially_refunded, :refunded], currency: "usd")
    Dispute.lost.joins(:order)
      .where(order_id: all_event_orders.select(:id), currency: "usd")
      .where("COALESCE(disputes.closed_at, disputes.updated_at) < ?", month_end)
      .where.not(id: lost_disputes_base.select(:id))
      .group("orders.event_id").sum(:amount_cents)
      .each { |event_id, cents| bridge[event_id] -= cents }

    bridge
  end

  def org_level_adjustment_rows(org_adjustments, nonprofit_org_ids)
    org_adjustments.keys.sort.filter_map do |org_id|
      adj = org_adjustments[org_id]
      opening = adj[:other_before]
      other_adj = adj[:other_month]
      closing = opening + other_adj
      reserve_held = adj[:reserve_held_month]
      reserve_released = adj[:reserve_released_month]
      ending_reserve = [-adj[:reserve_net_through_month], 0].max
      next if [opening, other_adj, closing, reserve_held, reserve_released, ending_reserve].all?(&:zero?)

      w9_nonprofit = nonprofit_org_ids.include?(org_id)
      {
        organization_id: org_id,
        event_id: nil,
        w9_nonprofit_classification: w9_nonprofit,
        drt_exemption_verified: DRT_VERIFIED_STATUS,
        nonprofit_exemption_note: w9_nonprofit ? NONPROFIT_NOTE : "",
        opening_custodial_liability_cents: opening,
        proceeds_collected_cents: 0,
        proceeds_refunded_cents: 0,
        chargebacks_cents: 0,
        organizer_processing_deducted_cents: 0,
        other_adjustments_cents: other_adj,
        organizer_payouts_made_cents: 0,
        payout_reversals_cents: 0,
        closing_custodial_liability_cents: closing,
        closing_custodial_payables_cents: [closing, 0].max,
        closing_organizer_deficits_cents: [-closing, 0].max,
        reserve_held_cents: reserve_held,
        reserve_released_cents: reserve_released,
        ending_reserve_balance_cents: ending_reserve,
        unallocated_refunds_exception_cents: 0,
        cumulative_unallocated_refunds_exception_cents: 0,
        reconciliation_exception_flag: false,
        non_custodial_settlement_bridge_cents: 0,
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
    nonprofit_count = rows.count { |row| row[:w9_nonprofit_classification] }
    exception_count = rows.count { |row| row[:reconciliation_exception_flag] }

    # Offset positive and negative balances ONLY within the same organization_id;
    # never net unrelated organizers against one another on the balance sheet.
    org_net_closing = rows.group_by { |row| row[:organization_id] }
      .transform_values { |org_rows| org_rows.sum { |row| row[:closing_custodial_liability_cents] } }
    closing_payables = org_net_closing.values.sum { |net| [net, 0].max }
    closing_deficits = org_net_closing.values.sum { |net| [-net, 0].max }

    bpt_base = sums[:bpt_base_fee_revenue_estimate_cents]
    sums.merge(
      organization_id: nil,
      event_id: nil,
      w9_nonprofit_classification: nil,
      drt_exemption_verified: DRT_VERIFIED_STATUS,
      w9_nonprofit_row_count: nonprofit_count,
      nonprofit_exemption_note: "#{nonprofit_count} W-9 nonprofit row(s); DRT exemption not tracked",
      closing_custodial_payables_cents: closing_payables,
      closing_organizer_deficits_cents: closing_deficits,
      reconciliation_exception_count: exception_count,
      reconciliation_exception_flag: exception_count.positive?,
      estimated_bpt_rate_pct: bpt_rate_pct,
      estimated_bpt_on_fee_revenue_estimate_cents: estimate_bpt_cents(bpt_base)
    )
  end

  def estimate_bpt_cents(base_cents)
    return 0 unless base_cents.positive?

    ((base_cents * bpt_rate_bps) + 5_000) / 10_000
  end

  def format_csv_row(row_type, row)
    w9_flag = case row[:w9_nonprofit_classification]
    when true then "yes"
    when false then "no"
    else ""
    end
    exc_flag = row[:reconciliation_exception_flag] ? "yes" : "no"
    [
      row_type,
      period,
      row[:organization_id],
      row[:event_id],
      w9_flag,
      row[:drt_exemption_verified].to_s,
      row[:nonprofit_exemption_note].to_s,
      FinanceExports.money(row[:opening_custodial_liability_cents]),
      FinanceExports.money(row[:proceeds_collected_cents]),
      FinanceExports.money(row[:proceeds_refunded_cents]),
      FinanceExports.money(row[:chargebacks_cents]),
      FinanceExports.money(row[:organizer_processing_deducted_cents]),
      FinanceExports.money(row[:other_adjustments_cents]),
      FinanceExports.money(row[:organizer_payouts_made_cents]),
      FinanceExports.money(row[:payout_reversals_cents]),
      FinanceExports.money(row[:closing_custodial_liability_cents]),
      FinanceExports.money(row[:closing_custodial_payables_cents]),
      FinanceExports.money(row[:closing_organizer_deficits_cents]),
      FinanceExports.money(row[:reserve_held_cents]),
      FinanceExports.money(row[:reserve_released_cents]),
      FinanceExports.money(row[:ending_reserve_balance_cents]),
      FinanceExports.money(row[:unallocated_refunds_exception_cents]),
      exc_flag,
      FinanceExports.money(row[:non_custodial_settlement_bridge_cents]),
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
