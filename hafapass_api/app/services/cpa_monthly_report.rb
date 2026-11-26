# frozen_string_literal: true

# Monthly CPA custodial-liability and Guam BPT preparation report for one Guam
# calendar month (Pacific/Guam, UTC+10). Read-only preparation aid — not a
# filed tax return. Separates organizer proceeds held in custody (a balance
# sheet liability) from HåfaPass ticketing service-fee revenue (income).
#
# Recording-time period-stability rule:
#   - Every movement is booked in the Guam calendar month its immutable record
#     was created (ledger row / append-only audit row `created_at`), never by
#     a later-supplied confirmation/effective date, never by current mutable
#     status, and never by mutable columns such as `updated_at`:
#     * Custodial captures: `agent_captures` only sees live/legacy USD Stripe
#       captures whose recording time is `< month_end`. For fulfilled orders
#       (`orders.completed_at IS NOT NULL`), custodial booking time is
#       `GREATEST(orders.completed_at, agent_cap.first_capture_created_at)`
#       (backfilled captures enter custody in their creation month labelled
#       `"Stripe capture backfill relates to <Mon YYYY>"`). For never-fulfilled
#       late captures (`orders.completed_at IS NULL`, e.g. expired/cancelled
#       door or online checkouts that captured late and auto-refunded),
#       custodial booking time is the capture recording time
#       `GREATEST(COALESCE(payments.succeeded_at, payments.created_at),
#       payments.created_at)`, leaving the earlier reservation month untouched
#       and labelling the capture month `"Late capture relates to <Mon YYYY>"`.
#       A never-fulfilled capture is owed back to the buyer, not the organizer:
#       its proceeds portion is booked in `buyer_refund_captures` (not
#       `proceeds_collected`), its refund in `buyer_refunds_paid` (not
#       `proceeds_refunded`), and the balance carries in
#       `closing_buyer_refunds_owed`, so organizer custody matches the payout
#       statement. "Never fulfilled" is Commerce::NeverFulfilledCapture: the
#       late-capture exception linked to the capture's own payment (see
#       #unfulfilled_capture_sql), shared with Settlements::Calculator. Its
#       service fee stays in fee revenue and fee refunds, as in the BPT detail
#       CSV; its Stripe processing is informational only (never organizer-borne
#       under the shared bearer switch). A lost dispute on it clears the buyer
#       balance, not organizer custody, capped per order so a refund and a
#       dispute cannot both clear it (#buyer_returns_by_event).
#     * Paid payouts: `COALESCE(paid_audit.created_at, payouts.paid_at)` across
#       all live (non-simulated) USD payouts. Audit joins rely on fields that
#       survive `DataRetention.anonymize!` (`action`, `auditable_id`,
#       `created_at`, and `payouts.status` transition cardinality), not only
#       redacted `after_data`.
#     * Payout reversals: `rev_audit.created_at` from the surviving-field
#       reversal audit join. Never falls back to `confirmed_at` or
#       `payouts.updated_at`. Reversed payouts missing reversal audit evidence
#       are excluded from closed-month CSV rows (so corrupt/auditless reversals
#       never rewrite closed months) and surfaced separately in top-level
#       `current_integrity_alerts`.
#     * Stripe processing fees (`FeeComponent` kind: "processing", estimated:
#       false, AppendOnlyRecord): strictly `fee_components.created_at`,
#       independent of current `stripe_fee_evidences.status`.
#     * Balance adjustments: strictly `balance_adjustments.created_at` (never
#       overridden by past or future `effective_at`, which remains for
#       `Settlements::Calculator` eligibility), scoped by immutable payment
#       custody (`agent_orders` and `agent_disputes_base`), independent of
#       current dispute status.
#     * Lost disputes: `COALESCE(dispute_lost_audit.created_at,
#       disputes.closed_at)` (never `disputes.updated_at`). Auditless lost
#       disputes that also lack `closed_at` have no reliable loss timestamp
#       (`disputes.created_at` is the opened date, not loss date), so they are
#       excluded from closed-month chargebacks and surfaced in
#       `current_integrity_alerts`.
#   - All queries execute inside a single REPEATABLE READ read-only transaction
#     snapshot (guarded when already inside an outer transaction) so refund and
#     allocation totals cannot drift mid-export.
#   - Monetary and period roll-forward columns in closed months stay
#     byte-identical across later activity and audit redaction; informational
#     W-9 nonprofit columns reflect current W-9 classification at export time.
#   - Reconciles to Settlements::Calculator via `non_custodial_settlement_bridge`
#     (non-custodial non-cash sales like Clover, their refunds/disputes, and
#     settlement adjustments linked to non-custodial orders or disputes).
class CpaMonthlyReport
  GUAM_TIMEZONE = TaxReports::GUAM_TIMEZONE
  NOTE = "Preparation aid only — not a filed return. Closed months are defined by immutable recording time (created_at); monetary and roll-forward columns stay byte-identical while prior-period movements are labelled in the recording month. W-9 nonprofit flags reflect the current W-9 at export time and can change if a W-9 is updated later; DRT exemptions are not tracked. Under our working position for CPA and counsel review, ticket and event proceeds collected as limited agent are a custodial liability owed to organizers, separate from HåfaPass service-fee revenue. Estimated Guam BPT applies the statutory 11 GCA § 26202(c) service-business rate (P.L. 38-136; P.L. 34-87 from Apr 2018) to net HåfaPass fee revenue only; confirm base, rate, any § 26203.2 small-business relief, and external DRT exemptions with your CPA."
  NONPROFIT_NOTE = "W-9 nonprofit (current at export time); DRT exemption not tracked — verify externally"
  DRT_VERIFIED_STATUS = "not_tracked"
  RATE_NOT_SUPPORTED = "not_supported"

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
    opening_buyer_refunds_owed
    buyer_refund_captures
    buyer_refunds_paid
    closing_buyer_refunds_owed
    reserve_held
    reserve_released
    ending_reserve_balance
    unallocated_refunds_exception
    cumulative_unallocated_refunds_exception
    reconciliation_exception_flag
    reconciliation_exception_note
    prior_period_note
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
    opening_buyer_owed_gross
    buyer_owed_captures_gross
    buyer_owed_returned_gross
    closing_buyer_owed_gross
    buyer_overpaid_in_month_gross
    buyer_overpaid_cumulative_gross
  ].freeze

  # Gross buyer liability on classified payments (design §8.5, P3), appended
  # after `currency` so existing positional consumers keep their columns.
  # From Commerce::ClassifiedPaymentFinance: captures at their recording time,
  # returns at their recognition time, signed.
  GROSS_BUYER_KEYS = %i[
    opening_buyer_owed_gross_cents
    buyer_owed_captures_gross_cents
    buyer_owed_returned_gross_cents
    closing_buyer_owed_gross_cents
    buyer_overpaid_in_month_gross_cents
    buyer_overpaid_cumulative_gross_cents
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
    opening_buyer_refunds_owed_cents
    buyer_refund_captures_cents
    buyer_refunds_paid_cents
    closing_buyer_refunds_owed_cents
    reserve_held_cents
    reserve_released_cents
    ending_reserve_balance_cents
    unallocated_refunds_exception_cents
    cumulative_unallocated_refunds_exception_cents
    non_custodial_settlement_bridge_cents
    backup_withholding_memo_cents
    fee_revenue_gross_cents
    fee_refunds_cents
    fee_revenue_net_cents
    stripe_processing_costs_cents
    bpt_base_fee_revenue_estimate_cents
  ].concat(GROSS_BUYER_KEYS).freeze

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

  # Statutory 11 GCA § 26202(c) service-business Guam BPT rate (basis points):
  #   - Oct 1, 2026+:          4.00% (P.L. 38-136)
  #   - Oct 1, 2025 – Sep 2026: 4.50% (P.L. 38-136)
  #   - Apr 1, 2018 – Sep 2025: 5.00% (P.L. 34-87)
  #   - Before Apr 1, 2018:     nil ("not_supported" — confirm historical rate with CPA)
  # Estimate only; excludes conditional § 26203.2 small-business relief.
  def bpt_rate_bps
    if year > 2026 || (year == 2026 && month >= 10)
      400
    elsif year > 2025 || (year == 2025 && month >= 10)
      450
    elsif year > 2018 || (year == 2018 && month >= 4)
      500
    end
  end

  def bpt_rate_pct
    bpt_rate_bps ? format("%.2f", bpt_rate_bps / 100.0) : RATE_NOT_SUPPORTED
  end

  def bpt_rate_note
    if year > 2025 || (year == 2025 && month >= 10)
      "#{bpt_rate_pct}% statutory § 26202(c) service-business BPT estimate (P.L. 38-136; excludes § 26203.2 small-business relief — confirm with CPA)"
    elsif bpt_rate_bps
      "#{bpt_rate_pct}% historical Guam BPT estimate (Apr 2018 – Sep 2025, P.L. 34-87; confirm applicable rate with CPA)"
    else
      "Periods before April 2018 are not supported for automatic Guam BPT estimation (the 5.00% rate took effect April 1, 2018 under P.L. 34-87) — confirm applicable historical rate with CPA"
    end
  end

  def report
    @report ||= with_consistent_snapshot { build_report }
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

  # Run every aggregate in one REPEATABLE READ read-only snapshot when no outer
  # transaction is open so concurrent writes cannot cause refund totals and
  # RefundItem allocations to disagree. Guarded like EventSeriesReport#call:
  # inside an already-open outer transaction (e.g. transactional specs or a
  # caller-managed transaction), it inherits the caller's isolation level
  # instead of raising ActiveRecord::TransactionIsolationError.
  def with_consistent_snapshot
    if ActiveRecord::Base.connection.open_transactions.zero?
      ActiveRecord::Base.transaction(isolation: :repeatable_read) do
        ActiveRecord::Base.connection.execute("SET TRANSACTION READ ONLY")
        yield
      end
    else
      yield
    end
  end

  def build_report
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
      w9_classification_as_of: "current_at_export_time",
      note: NOTE,
      rows: rows,
      totals: totals,
      current_integrity_alerts: build_current_integrity_alerts
    }
  end

  def month_start
    @month_start ||= ActiveSupport::TimeZone[GUAM_TIMEZONE].local(year, month, 1)
  end

  def month_end
    @month_end ||= month_start.next_month
  end

  def classified_finance
    @classified_finance ||= Commerce::ClassifiedPaymentFinance.new(month_start...month_end)
  end

  def gross_buyer_values(totals)
    return GROSS_BUYER_KEYS.index_with(0) unless totals

    {
      opening_buyer_owed_gross_cents: totals.owed.opening,
      buyer_owed_captures_gross_cents: totals.owed.added,
      buyer_owed_returned_gross_cents: totals.owed.returned,
      closing_buyer_owed_gross_cents: totals.owed.closing,
      buyer_overpaid_in_month_gross_cents: totals.excess_cents,
      buyer_overpaid_cumulative_gross_cents: totals.excess_cumulative_cents
    }
  end

  def format_guam_month(time)
    return nil unless time

    time.in_time_zone(GUAM_TIMEZONE).strftime("%b %Y")
  end

  CAPTURE_RECORDED_AT_SQL = <<~SQL.squish.freeze
    CASE
      WHEN orders.completed_at IS NOT NULL THEN payments.created_at
      ELSE GREATEST(COALESCE(payments.succeeded_at, payments.created_at), payments.created_at)
    END
  SQL

  def agent_captures
    @agent_captures ||= Payment.live_or_legacy_capture
      .joins(:order)
      .where(provider: "stripe", currency: "usd")
      .where("(#{CAPTURE_RECORDED_AT_SQL}) < ?", month_end)
      .where("LEFT(COALESCE(payments.provider_payment_id, ''), 4) <> 'sim_'")
      .where("payments.provider_payload->>'simulated' IS DISTINCT FROM 'true' AND payments.provider_payload->>'livemode' IS DISTINCT FROM 'false'")
  end

  # Never-fulfilled orders (no completed_at) that captured on Stripe at any
  # time. They are custodial from their capture's recording month only, so an
  # earlier month must not pull them into the non-custodial bridge either.
  def never_fulfilled_capture_order_ids
    Order.where(completed_at: nil)
      .where(id: Payment.live_or_legacy_capture.where(provider: "stripe", currency: "usd").select(:order_id))
      .select(:id)
  end

  def nonlive_stripe_order_ids
    @nonlive_stripe_order_ids ||= Payment.where(provider: "stripe")
      .where("payments.created_at < ?", month_end)
      .where(
        "provider_environment IN ('test', 'simulate') OR LEFT(COALESCE(provider_payment_id, ''), 4) = 'sim_' " \
        "OR provider_payload->>'simulated' = 'true' OR provider_payload->>'livemode' = 'false'"
      )
      .select(:order_id)
  end

  # Real (non-test, non-simulated) USD orders matching Settlements::Calculator
  # eligibility, plus never-fulfilled expired/cancelled orders that actually
  # recorded a live Stripe capture (so closed months stay immutable both before
  # and after a late-capture auto-refund flips order.status to refunded).
  def real_usd_orders
    @real_usd_orders ||= begin
      completed_base = Order.excluding_test_payments
        .where(status: [:completed, :partially_refunded, :refunded], currency: "usd")
        .where.not(id: nonlive_stripe_order_ids)
      captured_base = Order.excluding_test_payments
        .where(status: [:completed, :partially_refunded, :refunded, :expired, :cancelled], currency: "usd")
        .where(id: agent_captures.select(:order_id))
      completed_base.or(captured_base)
    end
  end

  # Earliest live/legacy non-simulated USD Stripe capture recorded on or before
  # month_end. A backfilled capture or a never-fulfilled late capture recorded
  # in a later month is invisible to earlier closed months and enters custodial
  # liability in the month the capture was recorded.
  def agent_capture_join_sql
    succeeded_statuses = Payment.statuses.values_at("succeeded", "partially_refunded", "refunded")
    ActiveRecord::Base.sanitize_sql_array([
      <<~SQL.squish,
        INNER JOIN (
          SELECT
            payments.order_id,
            MIN(payments.created_at) AS first_capture_created_at,
            MIN(GREATEST(COALESCE(payments.succeeded_at, payments.created_at), payments.created_at)) AS first_capture_recorded_at
          FROM payments
          INNER JOIN orders cap_orders ON cap_orders.id = payments.order_id
          WHERE payments.provider = 'stripe'
            AND payments.currency = 'usd'
            AND payments.status IN (?)
            AND (payments.provider_environment = 'live' OR (payments.provider_environment IS NULL AND payments.provider_payload->>'livemode' IS DISTINCT FROM 'false' AND payments.provider_payload->>'simulated' IS DISTINCT FROM 'true'))
            AND LEFT(COALESCE(payments.provider_payment_id, ''), 4) <> 'sim_'
            AND payments.provider_payload->>'simulated' IS DISTINCT FROM 'true'
            AND payments.provider_payload->>'livemode' IS DISTINCT FROM 'false'
            AND (
              CASE
                WHEN cap_orders.completed_at IS NOT NULL THEN payments.created_at
                ELSE GREATEST(COALESCE(payments.succeeded_at, payments.created_at), payments.created_at)
              END
            ) < ?
          GROUP BY payments.order_id
        ) agent_cap ON agent_cap.order_id = orders.id
      SQL
      succeeded_statuses,
      month_end
    ])
  end

  def agent_orders
    @agent_orders ||= real_usd_orders.where(id: agent_captures.select(:order_id))
  end

  # A capture HåfaPass never fulfilled (hold expired, inventory released, or
  # every pass night cancelled first) is owed back to the buyer. The shared
  # Commerce::NeverFulfilledCapture predicate decides it from the payment row
  # and the late-capture exception linked to that payment, so the same order
  # is classified the same way in every month, even when its capture and
  # exception straddle a Guam midnight, and Settlements::Calculator agrees.
  # Here the qualifying payment must also be a live USD Stripe agent capture
  # recorded before month end. completed_at alone is not enough: legacy
  # completed orders can have a null completed_at.
  def unfulfilled_capture_sql
    @unfulfilled_capture_sql ||= Commerce::NeverFulfilledCapture.order_sql(
      payment_sql: LIVE_AGENT_CAPTURE_SQL, recorded_before: month_end
    )
  end

  LIVE_AGENT_CAPTURE_SQL = <<~SQL.squish.freeze
    nf_pay.provider = 'stripe' AND nf_pay.currency = 'usd'
    AND (nf_pay.provider_environment = 'live' OR (nf_pay.provider_environment IS NULL
      AND nf_pay.provider_payload->>'livemode' IS DISTINCT FROM 'false'
      AND nf_pay.provider_payload->>'simulated' IS DISTINCT FROM 'true'))
    AND LEFT(COALESCE(nf_pay.provider_payment_id, ''), 4) <> 'sim_'
    AND nf_pay.provider_payload->>'simulated' IS DISTINCT FROM 'true'
    AND nf_pay.provider_payload->>'livemode' IS DISTINCT FROM 'false'
  SQL

  def fulfilled_custody_sql
    @fulfilled_custody_sql ||= "NOT #{unfulfilled_capture_sql}"
  end

  ORDER_CUSTODIAL_AT_SQL = <<~SQL.squish.freeze
    CASE
      WHEN orders.completed_at IS NOT NULL THEN
        GREATEST(orders.completed_at, agent_cap.first_capture_created_at)
      ELSE
        GREATEST(COALESCE(agent_cap.first_capture_recorded_at, orders.created_at), agent_cap.first_capture_created_at)
    END
  SQL

  def orders_before
    @orders_before ||= agent_orders.joins(agent_capture_join_sql)
      .where("#{ORDER_CUSTODIAL_AT_SQL} < ?", month_start)
  end

  def orders_in_month
    @orders_in_month ||= agent_orders.joins(agent_capture_join_sql)
      .where("#{ORDER_CUSTODIAL_AT_SQL} >= ? AND #{ORDER_CUSTODIAL_AT_SQL} < ?", month_start, month_end)
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

  # Disputes scoped strictly by immutable payment custody (order_id, payment_id,
  # provider are attr_readonly on Dispute), completely independent of current
  # mutable dispute status (open / won / lost).
  def agent_disputes_base
    @agent_disputes_base ||= begin
      base = Dispute.where(order_id: agent_orders.select(:id), provider: "stripe", currency: "usd")
      base.where(payment_id: nil).or(base.where(payment_id: agent_captures.select(:id)))
    end
  end

  def lost_disputes_base
    @lost_disputes_base ||= agent_disputes_base.lost
  end

  DISPUTE_LOST_AT_SQL = "COALESCE(dispute_lost_audit.created_at, disputes.closed_at)"
  PAID_RECORDED_AT_SQL = "COALESCE(paid_audit.created_at, payouts.paid_at)"
  REVERSAL_RECORDED_AT_SQL = "rev_audit.created_at"
  ADJUSTMENT_RECORDED_AT_SQL = "balance_adjustments.created_at"

  def dispute_lost_audit_join_sql
    <<~SQL.squish
      LEFT JOIN LATERAL (
        SELECT id, created_at
        FROM audit_logs
        WHERE audit_logs.auditable_type = 'Dispute'
          AND audit_logs.auditable_id = disputes.id
          AND audit_logs.action = 'dispute.lost'
        ORDER BY audit_logs.id ASC
        LIMIT 1
      ) dispute_lost_audit ON true
    SQL
  end

  def disputes_before
    @disputes_before ||= lost_disputes_base.joins(dispute_lost_audit_join_sql)
      .where("#{DISPUTE_LOST_AT_SQL} < ?", month_start)
  end

  def disputes_in_month
    @disputes_in_month ||= lost_disputes_base.joins(dispute_lost_audit_join_sql)
      .where("#{DISPUTE_LOST_AT_SQL} >= ? AND #{DISPUTE_LOST_AT_SQL} < ?", month_start, month_end)
  end

  # All live (non-simulated) USD payouts across EVERY event/organization —
  # never filtered by whether a Stripe order exists on the event.
  def live_usd_payouts
    @live_usd_payouts ||= Payout.where(currency: "usd")
      .where("LEFT(COALESCE(payouts.provider_payout_id, ''), 4) <> 'sim_'")
  end

  # Redaction-safe paid audit join: relies on immutable fields that survive
  # DataRetention.anonymize! (`action`, `auditable_id`, `created_at`). Because
  # Payout#may_reconcile_to? permits at most one transition to `paid` before a
  # terminal `paid -> reversed` transition, the earliest (`id ASC`) `payout.paid`
  # or redacted/paid `payout.reconciled` row on a payout with `paid_at` present
  # is its paid recording audit — even if `payouts.status` later flips to
  # `reversed` without a reversal audit.
  def paid_audit_join_sql
    <<~SQL.squish
      LEFT JOIN LATERAL (
        SELECT a.id, a.created_at
        FROM audit_logs a
        WHERE a.auditable_type = 'Payout'
          AND a.auditable_id = payouts.id
          AND (
            a.action = 'payout.paid'
            OR (a.action = 'payout.reconciled' AND a.after_data->>'status' = 'paid')
            OR (
              a.action = 'payout.reconciled'
              AND COALESCE(a.after_data->>'status', '') = ''
            )
          )
        ORDER BY a.id ASC
        LIMIT 1
      ) paid_audit ON true
    SQL
  end

  # Redaction-safe reversal audit join: matches `payout.reversed`, unredacted
  # `payout.reconciled` with `after_data->>'status' = 'reversed'`, or (after
  # DataRetention.anonymize! clears `after_data`) a later `payout.reconciled`
  # row on a `status = reversed` payout ONLY when an earlier paid/reconciled
  # audit (`earlier_a.id < a.id`) exists on the same payout. This prevents a
  # single redacted paid audit from ever being misread as a reversal when an
  # auditless reversal occurs later (which instead surfaces in
  # `current_integrity_alerts` without altering closed months).
  def reversal_audit_join_sql
    reversed_status = Payout.statuses.fetch("reversed")
    ActiveRecord::Base.sanitize_sql_array([
      <<~SQL.squish,
        LEFT JOIN LATERAL (
          SELECT a.id, a.created_at, a.metadata
          FROM audit_logs a
          WHERE a.auditable_type = 'Payout'
            AND a.auditable_id = payouts.id
            AND (
              a.action = 'payout.reversed'
              OR (a.action = 'payout.reconciled' AND a.after_data->>'status' = 'reversed')
              OR (
                a.action = 'payout.reconciled'
                AND COALESCE(a.after_data->>'status', '') = ''
                AND payouts.status = ?
                AND EXISTS (
                  SELECT 1 FROM audit_logs earlier_a
                  WHERE earlier_a.auditable_type = 'Payout'
                    AND earlier_a.auditable_id = payouts.id
                    AND earlier_a.action IN ('payout.reconciled', 'payout.paid')
                    AND earlier_a.id < a.id
                )
              )
            )
          ORDER BY a.id DESC
          LIMIT 1
        ) rev_audit ON true
      SQL
      reversed_status
    ])
  end

  # Recording-time paid payouts: booked in the month recorded (audit recording
  # time if reconciled via PayoutReconciler/webhook, else payouts.paid_at).
  # If a payout is recorded in Month M with an earlier bank confirmation date
  # (`payouts.paid_at < month_start`), it stays in Month M and adds a
  # prior-period label ("Payout relates to <Mon YYYY>").
  def paid_payouts_by_event(prior_period_labels)
    quoted_start = ActiveRecord::Base.connection.quote(month_start)
    in_month_expr = "#{PAID_RECORDED_AT_SQL} >= #{quoted_start}"

    before_amounts = Hash.new(0)
    month_amounts = Hash.new(0)
    month_withholding = Hash.new(0)

    scope = live_usd_payouts.where(status: [:paid, :reversed])
      .where.not(paid_at: nil)
      .joins(paid_audit_join_sql)
      .where("#{PAID_RECORDED_AT_SQL} < ?", month_end)

    scope.group("payouts.event_id", Arel.sql(in_month_expr))
      .pluck(
        "payouts.event_id",
        Arel.sql(in_month_expr),
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

    # Detect prior-period paid payouts (recorded in this month, bank paid_at earlier)
    scope.where("#{PAID_RECORDED_AT_SQL} >= ?", month_start)
      .where("payouts.paid_at < ?", month_start)
      .pluck("payouts.event_id", "payouts.paid_at")
      .each do |event_id, paid_at|
        label = format_guam_month(paid_at)
        prior_period_labels[event_id] << "Payout relates to #{label}" if label
      end

    [before_amounts, month_amounts, month_withholding]
  end

  # Recording-time payout reversals: strictly dated by the append-only reversal
  # audit row's recording time (`occurred_at` / `created_at`). Never uses
  # user-supplied `confirmed_at` or mutable `payouts.updated_at`.
  # Reversed payouts missing reversal audit evidence are NOT booked via
  # `updated_at`; instead they are returned in `missing_audit` to trigger a
  # reconciliation exception.
  def payout_reversals_by_event(prior_period_labels)
    quoted_start = ActiveRecord::Base.connection.quote(month_start)
    in_month_expr = "#{REVERSAL_RECORDED_AT_SQL} >= #{quoted_start}"

    before_amounts = Hash.new(0)
    month_amounts = Hash.new(0)
    month_withholding = Hash.new(0)

    audited_scope = live_usd_payouts.status_reversed
      .where.not(paid_at: nil)
      .joins(reversal_audit_join_sql)
      .where("rev_audit.id IS NOT NULL")
      .where("#{REVERSAL_RECORDED_AT_SQL} < ?", month_end)

    audited_scope.group("payouts.event_id", Arel.sql(in_month_expr))
      .pluck(
        "payouts.event_id",
        Arel.sql(in_month_expr),
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

    # Label reversals recorded in this month that relate to an earlier closed month
    audited_scope.where("#{REVERSAL_RECORDED_AT_SQL} >= ?", month_start)
      .pluck("payouts.event_id", "payouts.paid_at", Arel.sql("rev_audit.metadata->'reconciliation'->>'confirmed_at'"))
      .each do |event_id, paid_at, confirmed_at_str|
        confirmed_at = begin
          Time.iso8601(confirmed_at_str) if confirmed_at_str.present?
        rescue ArgumentError
          nil
        end
        related_time = if confirmed_at && confirmed_at < month_start
          confirmed_at
        elsif paid_at && paid_at < month_start
          paid_at
        end
        label = format_guam_month(related_time)
        prior_period_labels[event_id] << "Payout reversal relates to #{label}" if label
      end

    [before_amounts, month_amounts, month_withholding]
  end

  # Current-state ledger integrity alerts (as of export time), intentionally
  # kept OUTSIDE the closed-month CSV rows/totals so auditless/corrupt status
  # mutations made in a later month can NEVER alter a closed month's CSV bytes:
  #   1. Reversed USD payouts with paid_at present but no surviving reversal
  #      audit row (never booked via mutable payouts.updated_at).
  #   2. Lost custodial Stripe disputes lacking both a `dispute.lost` audit row
  #      and `closed_at` (cannot establish loss period from disputes.created_at).
  def build_current_integrity_alerts
    missing_reversals = live_usd_payouts.status_reversed
      .where.not(paid_at: nil)
      .joins(reversal_audit_join_sql)
      .where("rev_audit.id IS NULL")
      .order(:organization_id, :event_id, :id)
      .pluck(:organization_id, :event_id, :id, :amount_cents)
      .map do |org_id, event_id, payout_id, amount_cents|
        { organization_id: org_id, event_id: event_id, payout_id: payout_id, amount_cents: amount_cents.to_i }
      end

    auditless_disputes = lost_disputes_base.joins(dispute_lost_audit_join_sql)
      .joins(:order)
      .where("dispute_lost_audit.id IS NULL AND disputes.closed_at IS NULL")
      .order("orders.event_id", "disputes.id")
      .pluck("orders.event_id", "disputes.id", "disputes.amount_cents")
      .map do |event_id, dispute_id, amount_cents|
        { event_id: event_id, dispute_id: dispute_id, amount_cents: amount_cents.to_i }
      end

    notes = []
    rev_total = missing_reversals.sum { |item| item[:amount_cents] }
    disp_total = auditless_disputes.sum { |item| item[:amount_cents] }
    if rev_total.positive?
      notes << "Reversed payout(s) missing reversal audit evidence ($#{FinanceExports.money(rev_total)})"
    end
    if disp_total.positive?
      notes << "Lost dispute(s) missing dispute.lost audit and closed_at timestamp ($#{FinanceExports.money(disp_total)})"
    end
    classified_alerts = classified_finance.alerts
    if classified_alerts.any?
      notes << "#{classified_alerts.size} classified-payment item(s) not projected exactly " \
        "(#{classified_alerts.map { |alert| alert[:code] }.uniq.join(', ')})"
    end

    {
      as_of: "current_at_export_time",
      excluded_from_closed_month_csv: true,
      has_alerts: notes.any?,
      missing_reversal_audit_total_cents: rev_total,
      missing_reversal_audit_payouts: missing_reversals,
      auditless_lost_disputes_total_cents: disp_total,
      auditless_lost_disputes: auditless_disputes,
      classified_payment_alerts: classified_alerts,
      summary: notes.join("; ")
    }
  end

  def all_recorded_adjustments
    @all_recorded_adjustments ||= BalanceAdjustment.where(status: [:posted, :reversed], currency: "usd")
      .where("#{ADJUSTMENT_RECORDED_AT_SQL} < ?", month_end)
  end

  # Posted/reversed USD adjustments through month_end by recording time,
  # scoped by immutable payment custody (independent of mutable dispute status).
  def in_scope_adjustments
    @in_scope_adjustments ||= begin
      order_ok = all_recorded_adjustments.where(order_id: nil)
        .or(all_recorded_adjustments.where(order_id: agent_orders.select(:id)))
      dispute_ok = all_recorded_adjustments.where(dispute_id: nil)
        .or(all_recorded_adjustments.where(dispute_id: agent_disputes_base.select(:id)))
      order_ok.where(id: dispute_ok.select(:id))
    end
  end

  def build_rows
    prior_period_event_labels = Hash.new { |hash, key| hash[key] = [] }
    prior_period_org_labels = Hash.new { |hash, key| hash[key] = [] }

    # Fulfilled orders are organizer custody. Never-fulfilled captures (no
    # completed_at) are owed back to the buyer and never reach a payout.
    proceeds_before = OrderItem.joins(:order).where(order_id: orders_before.where(fulfilled_custody_sql).select(:id))
      .group("orders.event_id").sum(:organizer_proceeds_cents)
    proceeds_month = OrderItem.joins(:order).where(order_id: orders_in_month.where(fulfilled_custody_sql).select(:id))
      .group("orders.event_id").sum(:organizer_proceeds_cents)
    buyer_owed_before = OrderItem.joins(:order).where(order_id: orders_before.where(unfulfilled_capture_sql).select(:id))
      .group("orders.event_id").sum(:organizer_proceeds_cents)
    buyer_owed_month = OrderItem.joins(:order).where(order_id: orders_in_month.where(unfulfilled_capture_sql).select(:id))
      .group("orders.event_id").sum(:organizer_proceeds_cents)

    # Label late Stripe capture backfills and never-fulfilled late captures recorded
    # in this month for an order created/completed in an earlier closed month.
    orders_in_month
      .where("COALESCE(orders.completed_at, orders.created_at) < ?", month_start)
      .pluck("orders.event_id", "orders.completed_at", "orders.created_at")
      .each do |event_id, completed_at, created_at|
        if completed_at.present?
          label = format_guam_month(completed_at)
          prior_period_event_labels[event_id] << "Stripe capture backfill relates to #{label}" if label
        else
          label = format_guam_month(created_at)
          prior_period_event_labels[event_id] << "Late capture relates to #{label}" if label
        end
      end

    refunded_proceeds_before = RefundItem.joins(refund: :order).where(refund_id: refunds_before.select(:id))
      .where(fulfilled_custody_sql)
      .group("orders.event_id").sum("refund_items.organizer_proceeds_cents")
    refunded_proceeds_month = RefundItem.joins(refund: :order).where(refund_id: refunds_in_month.select(:id))
      .where(fulfilled_custody_sql)
      .group("orders.event_id").sum("refund_items.organizer_proceeds_cents")
    buyer_refunded_before, buyer_refunded_month, buyer_overpaid_before, buyer_overpaid_month = buyer_returns_by_event

    refunds_total_before = refunds_before.joins(:order).group("orders.event_id").sum(:amount_cents)
    refunds_total_month = refunds_in_month.joins(:order).group("orders.event_id").sum(:amount_cents)
    allocated_before = RefundItem.joins(refund: :order).where(refund_id: refunds_before.select(:id))
      .group("orders.event_id").sum("refund_items.amount_cents")
    allocated_month = RefundItem.joins(refund: :order).where(refund_id: refunds_in_month.select(:id))
      .group("orders.event_id").sum("refund_items.amount_cents")

    # A lost dispute on a never-fulfilled capture returns the buyer's money,
    # so it clears the buyer obligation (buyer_returns_by_event), never
    # organizer custody.
    chargebacks_before = disputes_before.joins(:order).where(fulfilled_custody_sql)
      .group("orders.event_id").sum(:amount_cents)
    chargebacks_month = disputes_in_month.joins(:order).where(fulfilled_custody_sql)
      .group("orders.event_id").sum(:amount_cents)

    # Label chargebacks lost in this month for disputes opened in an earlier closed month
    disputes_in_month.joins(:order).where(fulfilled_custody_sql)
      .where("disputes.opened_at < ?", month_start)
      .pluck("orders.event_id", "disputes.opened_at")
      .each do |event_id, opened_at|
        label = format_guam_month(opened_at)
        prior_period_event_labels[event_id] << "Chargeback relates to #{label}" if label
      end

    payouts_gross_before, payouts_gross_month, withholding_paid_month = paid_payouts_by_event(prior_period_event_labels)
    reversals_before, reversals_month, withholding_reversed_month = payout_reversals_by_event(prior_period_event_labels)

    fee_gross_month = FeeComponent.joins(:order).where(order_id: orders_in_month.select(:id), kind: "platform")
      .group("orders.event_id").sum(:amount_cents)
    fee_refunds_month = RefundItem.joins(refund: :order).where(refund_id: refunds_in_month.select(:id))
      .group("orders.event_id").sum("refund_items.fee_cents + refund_items.organizer_fee_cents")

    processing = processing_totals_by_event_sql(prior_period_event_labels)
    event_adjustments, org_adjustments = adjustment_totals_sql(prior_period_event_labels, prior_period_org_labels)
    settlement_bridge_by_event = non_custodial_settlement_bridge_by_event(prior_period_event_labels)

    # Union EVERY activity source before loading events so adjustment-only,
    # payout-only, Clover-only, and exception-only events are never omitted.
    candidate_event_ids = (
      proceeds_before.keys | proceeds_month.keys |
      refunded_proceeds_before.keys | refunded_proceeds_month.keys |
      buyer_owed_before.keys | buyer_owed_month.keys |
      buyer_refunded_before.keys | buyer_refunded_month.keys |
      buyer_overpaid_before.keys | buyer_overpaid_month.keys |
      refunds_total_before.keys | refunds_total_month.keys |
      chargebacks_before.keys | chargebacks_month.keys |
      payouts_gross_before.keys | payouts_gross_month.keys |
      reversals_before.keys | reversals_month.keys |
      fee_gross_month.keys | fee_refunds_month.keys |
      processing.keys | event_adjustments.keys |
      settlement_bridge_by_event.keys | classified_finance.by_event.keys
    )

    events = candidate_event_ids.empty? ? [] : Event.where(id: candidate_event_ids).order(:organization_id, :id).to_a
    all_org_ids = (events.map(&:organization_id) | org_adjustments.keys).uniq
    return [] if all_org_ids.empty?

    # Current W-9 tax_classification at export time (explicitly labelled in CSV/UI).
    nonprofit_org_ids = OrganizerTaxInformation.where(organization_id: all_org_ids, tax_classification: "nonprofit")
      .pluck(:organization_id).to_set

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

      buyer_opening = buyer_owed_before.fetch(event_id, 0) - buyer_refunded_before.fetch(event_id, 0)
      buyer_captured = buyer_owed_month.fetch(event_id, 0)
      buyer_paid = buyer_refunded_month.fetch(event_id, 0)
      buyer_closing = buyer_opening + buyer_captured - buyer_paid

      reserve_held = adj[:reserve_held_month]
      reserve_released = adj[:reserve_released_month]
      ending_reserve = [-adj[:reserve_net_through_month], 0].max

      unalloc_before = refunds_total_before.fetch(event_id, 0) - allocated_before.fetch(event_id, 0)
      unalloc_month = refunds_total_month.fetch(event_id, 0) - allocated_month.fetch(event_id, 0)
      unalloc_cumulative = unalloc_before + unalloc_month
      exception_notes = []
      if !unalloc_month.zero? || !unalloc_cumulative.zero?
        exception_notes << "Unallocated legacy refunds: $#{FinanceExports.money(unalloc_cumulative)} cumulative ($#{FinanceExports.money(unalloc_month)} in month)"
      end
      overpaid_month = buyer_overpaid_month.fetch(event_id, 0)
      overpaid_cumulative = buyer_overpaid_before.fetch(event_id, 0) + overpaid_month
      unless overpaid_cumulative.zero?
        exception_notes << "Never-fulfilled payment returned to the buyer twice (refund and lost dispute): " \
          "$#{FinanceExports.money(overpaid_cumulative)} ticket share cumulative " \
          "($#{FinanceExports.money(overpaid_month)} in month), a HåfaPass loss outside organizer custody"
      end
      has_exception = exception_notes.any?

      bridge_cents = settlement_bridge_by_event.fetch(event_id, 0)

      fee_gross = fee_gross_month.fetch(event_id, 0)
      fee_refund = fee_refunds_month.fetch(event_id, 0)
      fee_net = fee_gross - fee_refund
      gross_buyer = gross_buyer_values(classified_finance.for_event(event_id))

      active_values = gross_buyer.values + [
        opening, collected, refunded, chargebacks, proc_month_org, other_adj,
        payouts_made, payout_rev, closing,
        buyer_opening, buyer_captured, buyer_paid, buyer_closing,
        reserve_held, reserve_released, ending_reserve,
        unalloc_month, unalloc_cumulative, overpaid_cumulative, bridge_cents,
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
        opening_buyer_refunds_owed_cents: buyer_opening,
        buyer_refund_captures_cents: buyer_captured,
        buyer_refunds_paid_cents: buyer_paid,
        closing_buyer_refunds_owed_cents: buyer_closing,
        reserve_held_cents: reserve_held,
        reserve_released_cents: reserve_released,
        ending_reserve_balance_cents: ending_reserve,
        unallocated_refunds_exception_cents: unalloc_month,
        cumulative_unallocated_refunds_exception_cents: unalloc_cumulative,
        reconciliation_exception_flag: has_exception,
        reconciliation_exception_note: exception_notes.join("; "),
        prior_period_note: prior_period_event_labels[event_id].uniq.join("; "),
        non_custodial_settlement_bridge_cents: bridge_cents,
        backup_withholding_memo_cents: withholding_paid_month.fetch(event_id, 0) - withholding_reversed_month.fetch(event_id, 0),
        fee_revenue_gross_cents: fee_gross,
        fee_refunds_cents: fee_refund,
        fee_revenue_net_cents: fee_net,
        stripe_processing_costs_cents: proc_month_total,
        bpt_base_fee_revenue_estimate_cents: fee_net,
        estimated_bpt_rate_pct: bpt_rate_pct,
        estimated_bpt_on_fee_revenue_estimate_cents: estimate_bpt_cents(fee_net),
        **gross_buyer
      }
    end

    (event_rows + org_level_adjustment_rows(org_adjustments, nonprofit_org_ids, prior_period_org_labels))
      .sort_by { |row| [row[:organization_id], row[:event_id] || Float::INFINITY] }
  end

  # Buyer obligation on never-fulfilled captures, cleared by succeeded
  # refunds (RefundItem ticket share) and lost disputes (the dispute amount's
  # ticket share, allocated pro rata between the ticket share and the rest of
  # the payment), each in its own recording month. Clearing is capped per
  # order at the ticket share captured, so a refund after a lost dispute (or a
  # lost dispute after a refund) cannot clear the same obligation twice; the
  # excess is a HåfaPass loss, flagged as a reconciliation exception.
  # Returns per-event [cleared_before, cleared_month, overpaid_before, overpaid_month].
  def buyer_returns_by_event
    order_rows = agent_orders.where(unfulfilled_capture_sql).pluck(:id, :event_id, :total_cents)
    results = Array.new(4) { Hash.new(0) }
    return results if order_rows.empty?

    order_ids = order_rows.map(&:first)
    owed = OrderItem.where(order_id: order_ids).group(:order_id).sum(:organizer_proceeds_cents)
    returns = Hash.new { |hash, key| hash[key] = [] }

    refund_at = "COALESCE(refunds.succeeded_at, refunds.created_at)"
    RefundItem.joins(:refund)
      .where(refund_id: agent_refunds.where(order_id: order_ids).where("#{refund_at} < ?", month_end).select(:id))
      .group("refunds.order_id", Arel.sql(refund_at))
      .pluck("refunds.order_id", Arel.sql("#{refund_at} < #{ActiveRecord::Base.connection.quote(month_start)}"),
        Arel.sql("SUM(refund_items.organizer_proceeds_cents)"))
      .each { |order_id, before, cents| returns[order_id] << [before, cents.to_i] }

    totals = order_rows.to_h { |id, _event_id, total| [id, total.to_i] }
    lost_disputes_base.where(order_id: order_ids).joins(dispute_lost_audit_join_sql)
      .where("#{DISPUTE_LOST_AT_SQL} < ?", month_end)
      .pluck(:order_id, Arel.sql("#{DISPUTE_LOST_AT_SQL} < #{ActiveRecord::Base.connection.quote(month_start)}"), :amount_cents)
      .each do |order_id, before, amount|
        ticket = owed.fetch(order_id, 0)
        rest = [totals.fetch(order_id) - ticket, 0].max
        share = Commerce::MoneyAllocator.call(amount.to_i, [ticket, rest]).first
        returns[order_id] << [before, share]
      end

    cleared_before, cleared_month, overpaid_before, overpaid_month = results
    order_rows.each do |order_id, event_id, _total|
      ticket = owed.fetch(order_id, 0)
      returned_before = returns[order_id].select(&:first).sum(&:last)
      returned_total = returns[order_id].sum(&:last)
      cleared_through_start = returned_before.clamp(0, ticket)
      cleared_through_end = returned_total.clamp(0, ticket)
      cleared_before[event_id] += cleared_through_start
      cleared_month[event_id] += cleared_through_end - cleared_through_start
      overpaid_before[event_id] += returned_before - cleared_through_start
      overpaid_month[event_id] += (returned_total - cleared_through_end) - (returned_before - cleared_through_start)
    end
    results.each { |hash| hash.delete_if { |_event_id, cents| cents.zero? } }
  end

  # SQL-aggregated actual Stripe processing costs, period-dated strictly by
  # the immutable append-only recording time `fee_components.created_at`
  # (completely independent of current mutable `stripe_fee_evidences.status`).
  # Splits platform vs organizer share identically to Settlements::Calculator#processing_split:
  #   - Non-platform bearer (organizer / legacy nil): 100% organizer (pure SQL)
  #   - Platform bearer, ticket-only order: 100% platform (pure SQL)
  #   - Platform bearer, mixed ticket + add-on/donation order: pro-rata via Commerce::MoneyAllocator
  def processing_totals_by_event_sql(prior_period_labels)
    recorded_at_expr = "fee_components.created_at"
    quoted_start = ActiveRecord::Base.connection.quote(month_start)
    in_month_expr = "#{recorded_at_expr} >= #{quoted_start}"

    base = FeeComponent.joins(:order)
      .where(order_id: agent_orders.select(:id), kind: "processing", estimated: false)
      .where("#{recorded_at_expr} < ?", month_end)

    totals = Hash.new { |hash, key| hash[key] = [0, 0, 0] }

    # 0. Never-fulfilled captures have no organizer proceeds to deduct from, so
    #    their processing cost is HåfaPass's (informational total only). The
    #    bearer rule is shared with Settlements::Calculator and awaits
    #    Leon/CPA confirmation (Commerce::NeverFulfilledCapture).
    all_processing = base
    unless Commerce::NeverFulfilledCapture.organizer_bears_processing?
      base.where(unfulfilled_capture_sql)
        .where("#{recorded_at_expr} >= ?", month_start)
        .group("orders.event_id")
        .sum("fee_components.amount_cents")
        .each do |event_id, amount|
          totals[event_id][2] += amount.to_i
        end
      base = base.where(fulfilled_custody_sql)
    end

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

    # Label processing fees recorded in this month for captures booked in an earlier month
    all_processing.joins(agent_capture_join_sql)
      .where("#{recorded_at_expr} >= ?", month_start)
      .where("(#{ORDER_CUSTODIAL_AT_SQL}) < ?", month_start)
      .pluck("orders.event_id", Arel.sql(ORDER_CUSTODIAL_AT_SQL))
      .each do |event_id, order_at|
        label = format_guam_month(order_at)
        prior_period_labels[event_id] << "Processing fee relates to #{label}" if label
      end

    totals
  end

  def adjustment_totals_sql(prior_period_event_labels, prior_period_org_labels)
    event_totals = Hash.new { |hash, key| hash[key] = empty_adjustments.dup }
    org_totals = Hash.new { |hash, key| hash[key] = empty_adjustments.dup }

    quoted_start = ActiveRecord::Base.connection.quote(month_start)
    in_month_expr = "#{ADJUSTMENT_RECORDED_AT_SQL} >= #{quoted_start}"

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

    # Label adjustments recorded in this month whose effective_at was back-dated to an earlier month
    in_scope_adjustments
      .where("#{ADJUSTMENT_RECORDED_AT_SQL} >= ?", month_start)
      .where("balance_adjustments.effective_at < ?", month_start)
      .pluck(:organization_id, :event_id, :effective_at)
      .each do |org_id, event_id, effective_at|
        label = format_guam_month(effective_at)
        next unless label

        note = "Adjustment relates to #{label}"
        if event_id
          prior_period_event_labels[event_id] << note
        else
          prior_period_org_labels[org_id] << note
        end
      end

    [event_totals, org_totals]
  end

  # Bridges custodial Stripe closing liability to Settlements::Calculator across
  # ALL events with non-custodial activity (including Clover-only events):
  #   + net proceeds on non-custodial non-cash orders (e.g. organizer-direct Clover)
  #   - organizer share of any non-estimated processing fees on non-custodial orders
  #   - lost disputes on non-custodial orders or non-agent payments
  #   + settlement adjustments excluded from custodial scope (linked to non-custodial orders/disputes)
  def non_custodial_settlement_bridge_by_event(prior_period_event_labels)
    cash_order_ids = Order.where(payment_method: "door_cash")
      .or(Order.where(id: Payment.where(provider: "door_cash").where("payments.created_at < ?", month_end).select(:order_id)))
      .select(:id)

    non_custodial_orders = real_usd_orders
      .where("COALESCE(orders.completed_at, orders.created_at) < ?", month_end)
      .where.not(id: agent_orders.select(:id))
      .where.not(id: never_fulfilled_capture_order_ids)
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

    # Any non-estimated processing fees attached to non-custodial real orders
    non_custodial_real_orders = real_usd_orders
      .where("COALESCE(orders.completed_at, orders.created_at) < ?", month_end)
      .where.not(id: agent_orders.select(:id))
      .where.not(id: never_fulfilled_capture_order_ids)
    FeeComponent.joins(:order)
      .where(order_id: non_custodial_real_orders.select(:id), kind: "processing", estimated: false)
      .where("fee_components.created_at < ?", month_end)
      .where("orders.processing_fee_bearer_snapshot IS DISTINCT FROM 'platform'")
      .group("orders.event_id").sum("fee_components.amount_cents")
      .each { |event_id, cents| bridge[event_id] -= cents }

    # Non-custodial lost disputes: lost disputes on non-custodial real orders, plus
    # any lost disputes on agent orders whose payment_id is NOT a live Stripe capture.
    Dispute.lost.joins(:order).joins(dispute_lost_audit_join_sql)
      .where(order_id: real_usd_orders.select(:id), currency: "usd")
      .where("#{DISPUTE_LOST_AT_SQL} < ?", month_end)
      .where.not(id: lost_disputes_base.select(:id))
      .group("orders.event_id").sum(:amount_cents)
      .each { |event_id, cents| bridge[event_id] -= cents }

    # Event-level settlement adjustments excluded from custodial scope (e.g.,
    # manual_debit / manual_credit linked to a Clover order or non-agent dispute).
    bridge_adjustments = all_recorded_adjustments
      .where.not(event_id: nil)
      .where.not(kind: %w[reserve_hold reserve_release])
      .where.not(id: in_scope_adjustments.select(:id))

    bridge_adjustments
      .group(:event_id)
      .sum(:amount_cents)
      .each { |event_id, cents| bridge[event_id] += cents }

    # Label back-dated non-custodial bridge adjustments recorded in this month
    bridge_adjustments
      .where("#{ADJUSTMENT_RECORDED_AT_SQL} >= ?", month_start)
      .where("balance_adjustments.effective_at < ?", month_start)
      .pluck(:event_id, :effective_at)
      .each do |event_id, effective_at|
        label = format_guam_month(effective_at)
        prior_period_event_labels[event_id] << "Bridge adjustment relates to #{label}" if label
      end

    bridge.delete_if { |_event_id, cents| cents.zero? }
    bridge
  end

  def org_level_adjustment_rows(org_adjustments, nonprofit_org_ids, prior_period_org_labels)
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
        opening_buyer_refunds_owed_cents: 0,
        buyer_refund_captures_cents: 0,
        buyer_refunds_paid_cents: 0,
        closing_buyer_refunds_owed_cents: 0,
        reserve_held_cents: reserve_held,
        reserve_released_cents: reserve_released,
        ending_reserve_balance_cents: ending_reserve,
        unallocated_refunds_exception_cents: 0,
        cumulative_unallocated_refunds_exception_cents: 0,
        reconciliation_exception_flag: false,
        reconciliation_exception_note: "",
        prior_period_note: prior_period_org_labels[org_id].uniq.join("; "),
        non_custodial_settlement_bridge_cents: 0,
        backup_withholding_memo_cents: 0,
        fee_revenue_gross_cents: 0,
        fee_refunds_cents: 0,
        fee_revenue_net_cents: 0,
        stripe_processing_costs_cents: 0,
        bpt_base_fee_revenue_estimate_cents: 0,
        estimated_bpt_rate_pct: bpt_rate_pct,
        estimated_bpt_on_fee_revenue_estimate_cents: estimate_bpt_cents(0),
        **gross_buyer_values(nil)
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
    prior_period_rows = rows.select { |row| row[:prior_period_note].present? }

    total_exception_notes = []
    if !sums[:cumulative_unallocated_refunds_exception_cents].zero? || !sums[:unallocated_refunds_exception_cents].zero?
      total_exception_notes << "Unallocated legacy refunds: $#{FinanceExports.money(sums[:cumulative_unallocated_refunds_exception_cents])} cumulative ($#{FinanceExports.money(sums[:unallocated_refunds_exception_cents])} in month)"
    end

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
      nonprofit_exemption_note: "#{nonprofit_count} W-9 nonprofit row(s) (current at export time); DRT exemption not tracked",
      closing_custodial_payables_cents: closing_payables,
      closing_organizer_deficits_cents: closing_deficits,
      reconciliation_exception_count: exception_count,
      reconciliation_exception_flag: exception_count.positive?,
      reconciliation_exception_note: total_exception_notes.join("; "),
      prior_period_note: prior_period_rows.empty? ? "" : "#{prior_period_rows.size} row(s) with prior-period movements",
      estimated_bpt_rate_pct: bpt_rate_pct,
      estimated_bpt_on_fee_revenue_estimate_cents: estimate_bpt_cents(bpt_base)
    )
  end

  def estimate_bpt_cents(base_cents)
    return nil unless bpt_rate_bps
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
    rate_cell = row[:estimated_bpt_rate_pct] == RATE_NOT_SUPPORTED ? RATE_NOT_SUPPORTED : SpreadsheetExport::Amount.new(row[:estimated_bpt_rate_pct].to_s)
    bpt_cell = row[:estimated_bpt_on_fee_revenue_estimate_cents].nil? ? "" : FinanceExports.money(row[:estimated_bpt_on_fee_revenue_estimate_cents])
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
      FinanceExports.money(row[:opening_buyer_refunds_owed_cents]),
      FinanceExports.money(row[:buyer_refund_captures_cents]),
      FinanceExports.money(row[:buyer_refunds_paid_cents]),
      FinanceExports.money(row[:closing_buyer_refunds_owed_cents]),
      FinanceExports.money(row[:reserve_held_cents]),
      FinanceExports.money(row[:reserve_released_cents]),
      FinanceExports.money(row[:ending_reserve_balance_cents]),
      FinanceExports.money(row[:unallocated_refunds_exception_cents]),
      FinanceExports.money(row[:cumulative_unallocated_refunds_exception_cents]),
      exc_flag,
      row[:reconciliation_exception_note].to_s,
      row[:prior_period_note].to_s,
      FinanceExports.money(row[:non_custodial_settlement_bridge_cents]),
      FinanceExports.money(row[:backup_withholding_memo_cents]),
      FinanceExports.money(row[:fee_revenue_gross_cents]),
      FinanceExports.money(row[:fee_refunds_cents]),
      FinanceExports.money(row[:fee_revenue_net_cents]),
      FinanceExports.money(row[:stripe_processing_costs_cents]),
      FinanceExports.money(row[:bpt_base_fee_revenue_estimate_cents]),
      rate_cell,
      bpt_cell,
      "USD",
      *GROSS_BUYER_KEYS.map { |key| FinanceExports.money(row.fetch(key, 0)) }
    ]
  end
end
