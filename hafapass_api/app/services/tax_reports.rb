# frozen_string_literal: true

# Cash-basis preparation aid, not a filed return. Dates are Guam calendar dates.
#
# Classified (never-fulfilled) payments (design §8.2, A2): an order-scope
# classified order is never an organizer sale, so the organizer view leaves it
# out entirely. Its HåfaPass fee share is recognized from the capture's
# snapshot K at its capture recording time and reversed by its return
# postings (signed, P2 for lost disputes), and its attributed actual
# processing is a platform (or snapshot-organizer) cost, all from
# Commerce::ClassifiedPaymentFinance. RefundItems are never read for a
# classified payment, and a payment-scope second capture's refunds, losses
# and processing never reach the fulfilled sale's rows.
#
# Every ordinary refund is recognized at GREATEST(refund recording time,
# the order's collection time) (§5.3), so no month returns fees or proceeds
# before the sale that collected them.
class TaxReports
  NOTE = "HåfaPass's gross receipts are its service fees; ticket proceeds belong to organizers (agent model). Confirm with your accountant."
  GUAM_TIMEZONE = "Pacific/Guam"
  attr_reader :year

  def initialize(year)
    @year = Integer(year.to_s, 10)
    raise ArgumentError, "Choose a year from 2000 to 2100" unless (2000..2100).cover?(@year)
  end

  def as_json(*)
    { year: year, timezone: GUAM_TIMEZONE, currency: "usd", organizers: organizers, months: months, note: NOTE,
      classified_payment_policy: CpaMonthlyReport::CLASSIFIED_POLICY_NOTE,
      classified_payment_alerts: classified(period).alerts, payout_custody_alerts: payout_custody_alerts,
      payout_population_alerts: payout_population_alerts }
  end

  # Paid payouts this year whose BPT row uses the conservative rule instead
  # of a positive determination (current at read; not period-stable).
  def payout_custody_alerts
    paid = Payout.status_paid.where(paid_at: period, currency: "usd")
    undetermined = PayoutCustody.undetermined(paid).order(:id).pluck(:id, :event_id)
      .map { |id, event_id| { code: "payout_custody_undetermined", payout_id: id, event_id: event_id } }
    ambiguous = PayoutCustodyDetermination.where(payout_id: paid.select(:id), determination: "ambiguous")
      .joins(:payout).order(:payout_id).pluck(:payout_id, "payouts.event_id", :conservative_inclusion)
      .map do |id, event_id, included|
        { code: "payout_custody_ambiguous", payout_id: id, event_id: event_id, conservative_inclusion: included }
      end
    undetermined + ambiguous
  end

  def organizers
    @organizers ||= Organization.where(id: organization_ids).includes(:organizer_tax_information).order(:id).flat_map do |organization|
      event_ids = organization.events.select(:id)
      collected = collected_orders.where(event_id: event_ids)
      refunds = organizer_refunds.where(order_id: live_orders.where(event_id: event_ids).select(:id))
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

  def organization_ids
    @organization_ids ||= (
      collected_orders.joins(:event).distinct.pluck("events.organization_id") +
      organizer_refunds.joins(order: :event).distinct.pluck("events.organization_id") +
      paid_payouts.distinct.pluck(:organization_id)
    ).uniq.sort
  end

  def months
    (1..12).map do |month|
      range = month_period(month)
      collected = collected_orders(range)
      refunds = period_refunds(range)
      totals = classified(range).by_event.values
      collected_fees = fees(collected).sum(:amount_cents) + totals.sum { |event| event.fee_share_flow.added }
      returned_fees = refunded_fees(refunds) + totals.sum(&:fee_refund_cents)
      processing = ordinary_processing(range).sum(:amount_cents) +
        totals.sum { |event| event.processing_platform_cents + event.processing_organizer_cents }
      { month: month, fees_collected_cents: collected_fees, fees_refunded_cents: returned_fees,
        gross_receipts_cents: collected_fees - returned_fees, card_processing_costs_cents: processing }
    end
  end

  # Aggregate each ledger separately so multiple payments, refunds or payouts
  # cannot multiply a sale. IDs are sufficient to reconcile without names.
  def bpt_event_rows(month)
    range = month_period(month)
    # Only Stripe captures collect proceeds into the platform's account.
    captures = Payment.live_or_legacy_capture.where(provider: "stripe", currency: "usd")
      .where("LEFT(COALESCE(provider_payment_id, ''), 4) <> 'sim_'")
      .where("provider_payload->>'simulated' IS DISTINCT FROM 'true' AND provider_payload->>'livemode' IS DISTINCT FROM 'false'")
    agent_orders = live_orders(captures)
    collected = collected_orders(range, orders: agent_orders, captures: captures)
    refunds = period_refunds(range, orders: agent_orders, captures: captures)
    orders = collected.select(:id)
    classified_events = classified(range).by_event

    gross_fees = fees(collected).joins(:order).group("orders.event_id").sum(:amount_cents)
    returned_fees = RefundItem.joins(refund: :order).where(refund_id: refunds.select(:id))
      .group("orders.event_id").sum("refund_items.fee_cents + refund_items.organizer_fee_cents")
    processing = ordinary_processing(range, orders: agent_orders, captures: captures).group("orders.event_id").sum(:amount_cents)
    classified_events.each do |event_id, totals|
      gross_fees[event_id] = gross_fees.fetch(event_id, 0) + totals.fee_share_flow.added
      returned_fees[event_id] = returned_fees.fetch(event_id, 0) + totals.fee_refund_cents
      processing[event_id] = processing.fetch(event_id, 0) + totals.processing_platform_cents + totals.processing_organizer_cents
    end
    ticket_proceeds = OrderItem.item_ticket.joins(:order).where(order_id: orders)
      .group("orders.event_id").sum("order_items.subtotal_cents - order_items.discount_cents")
    # R2-2: a payout row needs its frozen custody determination (PayoutCustody),
    # never a live test of the event's current orders.
    payouts = PayoutCustody.bpt_payouts(Payout.status_paid.where(paid_at: range, currency: "usd"))
    disbursed = payouts.group(:event_id).sum("amount_cents - withheld_cents - carried_withholding_cents")
    check_adjustments = PayoutCheckAdjustment.joins(:payout).where(payout_id: payouts.where(provider: "check").select(:id))
      .group("payouts.event_id").sum(:amount_cents)

    event_ids = gross_fees.keys | returned_fees.keys | processing.keys | ticket_proceeds.keys | disbursed.keys
    Event.where(id: event_ids).order(:organization_id, :id).pluck(:id, :organization_id).filter_map do |event_id, organization_id|
      gross = gross_fees.fetch(event_id, 0)
      refunded = returned_fees.fetch(event_id, 0)
      costs = processing.fetch(event_id, 0)
      face_value = ticket_proceeds.fetch(event_id, 0)
      paid = disbursed.fetch(event_id, 0) + check_adjustments.fetch(event_id, 0)
      next if [gross, refunded, costs, face_value, paid].all?(&:zero?)

      [organization_id, event_id, gross, refunded, gross - refunded, costs, face_value, paid]
    end
  end

  private

  def month_period(month)
    month = Integer(month.to_s, 10)
    raise ArgumentError unless (1..12).cover?(month)

    start = month_start(month)
    start...start.next_month
  end

  def month_start(month)
    ActiveSupport::TimeZone[GUAM_TIMEZONE].local(year, month, 1)
  end

  def period
    month_start(1)...month_start(1).next_year
  end

  def live_orders(captured = Payment.live_or_legacy_capture)
    # The shared scope is production-only; enforce live evidence in every env.
    # Include expired/cancelled orders that still recorded a live capture
    # (never-fulfilled late captures) so closed months stay stable before and
    # after an auto-refund flips order.status to refunded. Only a qualifying
    # capture counts (Commerce::SaleCustody, shared with CpaMonthlyReport): a
    # classified Stripe second capture never makes a Clover sale collected.
    qualifying = captured.joins("INNER JOIN orders live_capture_orders ON live_capture_orders.id = payments.order_id")
      .where(Commerce::SaleCustody.qualifying_sql("payments", "live_capture_orders")).select("payments.order_id")
    Order.excluding_test_payments
      .where(status: [:completed, :partially_refunded, :refunded, :expired, :cancelled], currency: "usd")
      .where(id: qualifying)
  end

  # The CPA's custody booking time (Commerce::SaleCustody): completion, but
  # never before the first qualifying capture was recorded.
  COLLECTED_AT_SQL = Commerce::SaleCustody.booked_at_sql("order_captures").freeze
  REFUND_RECORDED_AT_SQL = "COALESCE(refunds.succeeded_at, refunds.created_at)"
  # §5.3: an ordinary refund is recognized no earlier than its order's
  # collection, the same rule CpaMonthlyReport applies to its buckets.
  REFUND_RECOGNIZED_AT_SQL = "GREATEST(#{REFUND_RECORDED_AT_SQL}, #{COLLECTED_AT_SQL})".freeze

  def order_captures_join_sql(captures)
    Commerce::SaleCustody.capture_times_join_sql(captures, "order_captures")
  end

  # Ordinary (organizer) sales only: an order-scope classified order is read
  # from Commerce::ClassifiedPaymentFinance.
  def collected_orders(range = period, orders: live_orders, captures: Payment.live_or_legacy_capture)
    orders
      .where("NOT #{Commerce::ClassifiedPaymentFinance::CLASSIFIED_ORDER_SQL}")
      .joins(order_captures_join_sql(captures))
      .where("(#{COLLECTED_AT_SQL}) >= ? AND (#{COLLECTED_AT_SQL}) < ?", range.begin, range.end)
  end

  # Ordinary refunds recognized in the range. A refund on a classified
  # payment or order is its posting, never a RefundItem. CodeRabbit
  # 4704013205: only a refund on a qualifying payment of `captures` (the
  # sale's own capture, Commerce::SaleCustody), or with no payment recorded
  # (legacy), so a refund on an unclassified second capture of a fulfilled
  # order that reconcile has not classified yet is in none of the monthly,
  # annual or BPT views (they all read this population).
  def period_refunds(range = period, orders: live_orders, captures: Payment.live_or_legacy_capture)
    qualifying = captures.joins(:order).where(Commerce::SaleCustody.qualifying_sql).select(:id)
    Refund.succeeded.where(order_id: orders.select(:id))
      .where("NOT #{Commerce::ClassifiedPaymentFinance::CLASSIFIED_REFUND_SQL}")
      .where("refunds.payment_id IS NULL OR refunds.payment_id IN (#{qualifying.to_sql})")
      .joins(:order).joins(order_captures_join_sql(captures))
      .where("#{REFUND_RECOGNIZED_AT_SQL} >= ? AND #{REFUND_RECOGNIZED_AT_SQL} < ?", range.begin, range.end)
  end

  # Actual processing on ordinary sales recognized in the range, without
  # components a classified payment owns (a second capture's processing on a
  # fulfilled order included). CodeRabbit 4704932984: recognized at
  # GREATEST(the component's recording, the order's custody booking), the
  # rule CpaMonthlyReport applies (§5.3), independently of the month the
  # sale was collected: a January sale's processing recorded in February is
  # February's cost in both, and a regenerated January is unchanged.
  PROCESSING_RECOGNIZED_AT_SQL = "GREATEST(fee_components.created_at, #{COLLECTED_AT_SQL})".freeze

  def ordinary_processing(range, orders: live_orders, captures: Payment.live_or_legacy_capture)
    ordinary = orders.where("NOT #{Commerce::ClassifiedPaymentFinance::CLASSIFIED_ORDER_SQL}")
    FeeComponent.joins(:order).joins(order_captures_join_sql(captures))
      .where(order_id: ordinary.select(:id), kind: "processing", estimated: false)
      .where("NOT #{Commerce::ClassifiedPaymentFinance::CLASSIFIED_COMPONENT_SQL}")
      .where("#{PROCESSING_RECOGNIZED_AT_SQL} >= ? AND #{PROCESSING_RECOGNIZED_AT_SQL} < ?", range.begin, range.end)
  end

  def classified(range)
    @classified ||= {}
    @classified[range] ||= Commerce::ClassifiedPaymentFinance.new(range)
  end

  # Review finding 5 (e49e94d2): an ordinary refund is the organizer's only
  # on the sale's own payment (Commerce::SaleCustody: the order's recorded
  # fulfilling payment, else any capture, never a payment-scope classified
  # capture), or with no payment recorded (legacy). A refund on another
  # payment of the order is not organizer activity.
  OWN_PAYMENT_REFUND_SQL = ("refunds.payment_id IS NULL OR EXISTS (SELECT 1 FROM payments own_payment " \
    "WHERE own_payment.id = refunds.payment_id AND #{Commerce::SaleCustody.qualifying_sql('own_payment', 'orders')})").freeze

  def organizer_refunds(range = period)
    period_refunds(range).where(OWN_PAYMENT_REFUND_SQL)
  end

  # The annual organizer view's payouts: the population verified at
  # a0b25ffe, unchanged by A2 (review finding 5, e49e94d2). A paid USD payout
  # in the year on an event with a live or legacy capture from any provider
  # (a Clover event's payout included), under the original live-order rule.
  # Frozen against later activity: the capture must be recorded by the
  # payout's paid recording (the redaction-safe paid audit, else paid_at),
  # the bound PayoutCustody's conservative rule uses, or the payout's frozen
  # determination already records Stripe custody. Only the BPT detail CSV
  # restricts payouts to Stripe custody (PayoutCustody.bpt_payouts).
  # AnnualPayeeReport keeps its own population; this view adopts no CPA rule.
  def paid_payouts(range = period)
    scope = Payout.status_paid.where(paid_at: range, currency: "usd")
    captured = Payment.live_or_legacy_capture.where(order_id: payout_population_orders.select(:id))
      .joins("INNER JOIN orders population_orders ON population_orders.id = payments.order_id")
      .where("population_orders.event_id = payouts.event_id")
      .where(CAPTURED_BY_PAID_SQL)
    frozen = PayoutCustodyDetermination.where("payout_custody_determinations.payout_id = payouts.id")
      .where("payout_custody_determinations.determination = 'stripe_custody' OR " \
        "(payout_custody_determinations.determination = 'ambiguous' AND payout_custody_determinations.conservative_inclusion)")
    Payout.where(id: scope.joins(PayoutCustody::PAID_AUDIT_JOIN_SQL)
      .where("EXISTS (#{captured.select(1).to_sql}) OR EXISTS (#{frozen.select(1).to_sql})").select(:id))
  end

  # A capture recorded by the payout's paid recording. A capture with no
  # recording stamp predates A1: bounded by the A1 cutover, else its success.
  # CodeRabbit 4704932992: a legacy capture with neither (a pre-trigger row
  # whose order has no completed_at) has no provable time before the
  # payout, so it is not affirmative support. Such a payout stays in the
  # view only through its frozen determination (an authorized baseline or
  # finance disposition via payout_custody:derive) and is otherwise left
  # out and reported (payout_population_alerts); no period policy is
  # assumed for it.
  CAPTURED_BY_PAID_SQL = <<~SQL.squish.freeze
    (payments.capture_recorded_at <= #{PayoutCustody::PAID_RECORDED_AT_SQL}
      OR (payments.capture_recorded_at IS NULL AND (
        (SELECT fc.recorded_at FROM financial_cutovers fc WHERE fc.key = 'a1_capture_recording') <= #{PayoutCustody::PAID_RECORDED_AT_SQL}
        OR payments.succeeded_at <= #{PayoutCustody::PAID_RECORDED_AT_SQL})))
  SQL
  UNTIMED_CAPTURE_SQL = <<~SQL.squish.freeze
    (payments.capture_recorded_at IS NULL AND payments.succeeded_at IS NULL
      AND COALESCE((SELECT fc.recorded_at FROM financial_cutovers fc WHERE fc.key = 'a1_capture_recording') >
        #{PayoutCustody::PAID_RECORDED_AT_SQL}, true))
  SQL

  # Paid payouts in the year left out of the annual organizer view only
  # because their event's capture has no provable time (CAPTURED_BY_PAID_SQL):
  # finance freezes their determination from the published baseline or a
  # disposition, or they stay out. Current at read.
  def payout_population_alerts
    included = paid_payouts.select(:id)
    untimed = Payment.live_or_legacy_capture.where(order_id: payout_population_orders.select(:id))
      .joins("INNER JOIN orders population_orders ON population_orders.id = payments.order_id")
      .where("population_orders.event_id = payouts.event_id").where(UNTIMED_CAPTURE_SQL)
    Payout.status_paid.where(paid_at: period, currency: "usd").where.not(id: included)
      .joins(PayoutCustody::PAID_AUDIT_JOIN_SQL).where("EXISTS (#{untimed.select(1).to_sql})")
      .order(:id).pluck(:id, :event_id)
      .map { |id, event_id| { code: "payout_capture_time_unproven", payout_id: id, event_id: event_id } }
  end

  # a0b25ffe's live_orders, kept exact for the annual payout population.
  def payout_population_orders
    Order.excluding_test_payments
      .where(status: [:completed, :partially_refunded, :refunded, :expired, :cancelled], currency: "usd")
      .where(id: Payment.live_or_legacy_capture.select(:order_id))
  end

  def fees(orders)
    FeeComponent.where(order_id: orders.select(:id), kind: "platform")
  end

  def refunded_fees(refunds)
    RefundItem.where(refund_id: refunds.select(:id)).sum("fee_cents + organizer_fee_cents")
  end
end
