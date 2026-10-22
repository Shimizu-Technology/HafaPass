# frozen_string_literal: true

# Read-only, organization-wide view of the same settlement math the event
# finance section uses. It never finalizes, snapshots, or changes records.
#
# Performance: this runs Settlements::Calculator once per event with money
# activity (a few queries each). That is fine for launch-sized organizations;
# cache or snapshot per event if an organization grows to hundreds of events.
class OrganizationFinanceSummary
  SETTLED_ORDER_STATUSES = %i[completed partially_refunded refunded].freeze
  IN_FLIGHT_PAYOUT_STATUSES = %i[pending processing].freeze
  HELD_PAYOUT_STATUSES = %i[held].freeze
  CASH_CUSTODY_KINDS = %w[organizer_retained_cash organizer_cash_return].freeze
  RECENT_PAYOUT_LIMIT = 50
  EARNING_COLUMNS = (Settlement::MONEY_COLUMNS - %i[paid_cents negative_balance_cents]).freeze

  def self.call(organization)
    new(organization).call
  end

  def self.payout_json(payout)
    {
      id: payout.id,
      event_id: payout.event_id,
      event_title: payout.event.title,
      settlement_version: payout.settlement.version,
      amount_cents: payout.amount_cents,
      currency: payout.currency,
      status: payout.status,
      provider: payout.provider,
      provider_payout_id: payout.provider_payout_id,
      failure_message: payout.failure_message,
      initiated_at: payout.initiated_at,
      paid_at: payout.paid_at,
      created_at: payout.created_at
    }
  end

  def initialize(organization)
    @organization = organization
  end

  def call
    rows = event_rows
    {
      organization: { id: organization.id, name: organization.name, slug: organization.slug,
                      timezone: organization.timezone },
      currency: organization.currency,
      totals: totals(rows),
      breakdown: breakdown(rows),
      orders_without_items_count: orders_without_items_count,
      events: rows,
      payouts: recent_payouts,
      payouts_count: organization.payouts.count,
      processing_fee_bearers: processing_fee_bearers,
      generated_at: Time.current
    }
  end

  private

  attr_reader :organization

  # Events with any money activity. Calculating every draft would add work
  # without adding a row an organizer can act on.
  def financial_events
    settled = Order.excluding_test_payments.where(status: SETTLED_ORDER_STATUSES).select(:event_id)
    organization.events
      .where(id: settled).or(organization.events.where(id: organization.settlements.select(:event_id)))
      .or(organization.events.where(id: organization.payouts.select(:event_id)))
      .or(organization.events.where(id: organization.balance_adjustments.where.not(event_id: nil).select(:event_id)))
      .order(starts_at: :desc, id: :desc)
  end

  def event_rows
    events = financial_events.to_a
    ids = events.map(&:id)
    latest = latest_settlements(ids)
    payouts = organization.payouts.where(event_id: ids).group(:event_id, :status).sum(:amount_cents)
    @sales = item_sales(ids)
    @refunded_proceeds = refunded_proceeds(ids)
    @buyer_fees = Order.excluding_test_payments.where(event_id: ids, status: SETTLED_ORDER_STATUSES).group(:event_id).sum(:service_fee_cents)
    events.map { |event| event_row(event, latest[event.id], payouts) }
  end

  # Line-item sales (tickets and add-ons) and their discounts: the same rows
  # organizer proceeds are built from, so the breakdown reconciles.
  def item_sales(event_ids)
    OrderItem.joins(:order).where(orders: { event_id: event_ids, status: SETTLED_ORDER_STATUSES })
      .merge(Order.excluding_test_payments)
      .group("orders.event_id").pluck(Arel.sql("orders.event_id, SUM(order_items.subtotal_cents), SUM(order_items.discount_cents)"))
      .to_h { |event_id, subtotal, discount| [event_id, [subtotal.to_i, discount.to_i]] }
  end

  def refunded_proceeds(event_ids)
    RefundItem.joins(refund: :order)
      .where(refunds: { status: Refund.statuses[:succeeded] }, orders: { event_id: event_ids, status: SETTLED_ORDER_STATUSES })
      .merge(Order.excluding_test_payments)
      .group("orders.event_id").sum(:organizer_proceeds_cents)
  end

  def latest_settlements(event_ids)
    Settlement.where(event_id: event_ids)
      .select("DISTINCT ON (event_id) settlements.*")
      .order(:event_id, version: :desc)
      .index_by(&:event_id)
  end

  def event_row(event, settlement, payouts)
    result = Settlements::Calculator.call(event)
    preview = result.attributes
    paid = payouts.fetch([event.id, "paid"], 0)
    in_flight = IN_FLIGHT_PAYOUT_STATUSES.sum { |status| payouts.fetch([event.id, status.to_s], 0) }
    held = payouts.fetch([event.id, "held"], 0)
    # Balance before payouts, unfloored: the calculator floors payable at 0,
    # which would hide an event that refunds or disputes pushed below zero.
    balance = preview[:organizer_proceeds_cents] - preview[:processing_fee_cents] - preview[:reserve_cents] +
      preview[:adjustment_cents]
    owed = [preview[:payable_cents] - paid - in_flight - held, 0].max
    sales, item_discounts = @sales.fetch(event.id, [0, 0])
    refunded = @refunded_proceeds.fetch(event.id, 0)
    cash = door_cash_retained(result.items)
    statement_current = statement_current?(settlement, preview)
    # PayoutCreator only pays from a version whose digest still matches, and a
    # payout is itself statement activity, so each further payout needs one.
    payable_version = settlement&.status_finalized? && settlement.source_digest == preview[:source_digest]
    requestable = payable_version ? [settlement.available_to_payout_cents, owed].min : 0
    {
      id: event.id,
      title: event.title,
      slug: event.slug,
      status: event.status,
      starts_at: event.starts_at,
      timezone: event.timezone,
      gross_cents: preview[:gross_cents],
      discount_cents: preview[:discount_cents],
      refund_cents: preview[:refund_cents],
      platform_fee_cents: preview[:platform_fee_cents],
      processing_fee_cents: preview[:processing_fee_cents],
      platform_processing_fee_cents: preview[:platform_processing_fee_cents],
      organizer_proceeds_cents: preview[:organizer_proceeds_cents],
      sales_cents: sales,
      item_discount_cents: item_discounts,
      # Whatever separates line-item sales from proceeds that is not a
      # discount or refund: the service fee share the organizer absorbed.
      absorbed_fee_cents: sales - item_discounts - refunded - preview[:organizer_proceeds_cents],
      refunded_proceeds_cents: refunded,
      buyer_fee_cents: @buyer_fees.fetch(event.id, 0),
      door_cash_retained_cents: cash,
      reserve_cents: preview[:reserve_cents],
      other_adjustment_cents: preview[:adjustment_cents] + cash,
      balance_cents: balance,
      payable_cents: preview[:payable_cents],
      paid_cents: paid,
      in_flight_cents: in_flight,
      held_cents: held,
      owed_cents: owed,
      negative_balance_cents: preview[:negative_balance_cents],
      settlement: settlement && {
        id: settlement.id,
        version: settlement.version,
        status: settlement.status,
        finalized_at: settlement.finalized_at,
        current: statement_current,
        payable: payable_version,
        available_to_payout_cents: settlement.available_to_payout_cents
      },
      requestable_cents: requestable,
      settlement_state: settlement_state(settlement, statement_current),
      payout_state: payout_state(owed: owed, in_flight: in_flight, held: held, paid: paid, requestable: requestable,
        finalized: settlement&.status_finalized?)
    }
  end

  # Payouts change a statement's digest but not what the organizer earned, so
  # "current" compares the approved money figures other than payout totals.
  def statement_current?(settlement, preview)
    return false unless settlement&.status_finalized?

    EARNING_COLUMNS.all? { |column| settlement.public_send(column) == preview[column] }
  end

  def door_cash_retained(items)
    custody = items.select do |item|
      item[:kind] == "adjustment" && CASH_CUSTODY_KINDS.include?(item.dig(:metadata, :adjustment_kind))
    end
    -custody.sum { |item| item[:amount_cents] }
  end

  # not_finalized: no approved statement yet; changed: activity since the
  # latest approved version, so a new version is needed; finalized: current.
  def settlement_state(settlement, statement_current)
    return "not_finalized" unless settlement&.status_finalized?

    statement_current ? "finalized" : "changed"
  end

  # ready: a payout can be requested now; needs_new_version: money is owed
  # but activity since the latest version (a refund, or the last payout
  # itself) means a new version must be finalized first.
  def payout_state(owed:, in_flight:, held:, paid:, requestable:, finalized:)
    return "on_hold" if held.positive?
    return "in_progress" if in_flight.positive?
    if owed.positive?
      return "ready" if requestable.positive?

      return finalized ? "needs_new_version" : "awaiting_statement"
    end

    paid.positive? ? "paid" : "nothing_owed"
  end

  # requestable_cents is what PayoutCreator would accept now: current
  # finalized versions, capped by the organization-wide payout balance.
  def totals(rows)
    sum = ->(key) { rows.sum { |row| row[key] } }
    available = OrganizationPayoutBalance.available_cents(organization)
    {
      gross_cents: sum.call(:gross_cents),
      discount_cents: sum.call(:discount_cents),
      refund_cents: sum.call(:refund_cents),
      platform_fee_cents: sum.call(:platform_fee_cents),
      processing_fee_cents: sum.call(:processing_fee_cents),
      platform_processing_fee_cents: sum.call(:platform_processing_fee_cents),
      organizer_proceeds_cents: sum.call(:organizer_proceeds_cents),
      door_cash_retained_cents: sum.call(:door_cash_retained_cents),
      payable_cents: sum.call(:payable_cents),
      paid_cents: organization.payouts.status_paid.sum(:amount_cents),
      in_flight_cents: organization.payouts.where(status: IN_FLIGHT_PAYOUT_STATUSES).sum(:amount_cents),
      held_cents: organization.payouts.status_held.sum(:amount_cents),
      owed_cents: sum.call(:owed_cents),
      negative_balance_cents: sum.call(:negative_balance_cents),
      requestable_cents: [sum.call(:requestable_cents), available].min,
      available_to_payout_cents: available
    }
  end

  # Organization-wide steps that sum exactly, from the proceeds side:
  # proceeds = sales - discounts - fees absorbed - refunded proceeds;
  # earned = proceeds - processing - door cash - reserves + adjustments;
  # balance = earned - paid out - in progress. Events are not floored
  # individually, so an overpaid event offsets the others, as payouts do.
  def breakdown(rows)
    sum = ->(key) { rows.sum { |row| row[key] } }
    organization_adjustments = organization.balance_adjustments.effective.where(event_id: nil).sum(:amount_cents)
    earned = sum.call(:balance_cents) + organization_adjustments
    paid = organization.payouts.status_paid.sum(:amount_cents)
    in_flight = organization.payouts.where(status: IN_FLIGHT_PAYOUT_STATUSES).sum(:amount_cents)
    held = organization.payouts.status_held.sum(:amount_cents)
    balance = earned - paid - in_flight - held
    {
      sales_cents: sum.call(:sales_cents),
      discount_cents: sum.call(:item_discount_cents),
      absorbed_fee_cents: sum.call(:absorbed_fee_cents),
      refunded_proceeds_cents: sum.call(:refunded_proceeds_cents),
      proceeds_cents: sum.call(:organizer_proceeds_cents),
      processing_fee_cents: sum.call(:processing_fee_cents),
      door_cash_retained_cents: sum.call(:door_cash_retained_cents),
      reserve_cents: sum.call(:reserve_cents),
      adjustment_cents: sum.call(:other_adjustment_cents) + organization_adjustments,
      earned_cents: earned,
      paid_cents: paid,
      in_flight_cents: in_flight,
      held_cents: held,
      balance_cents: balance,
      owed_cents: [balance, 0].max,
      negative_balance_cents: [-balance, 0].max,
      # Informational only; not steps in the sum.
      buyer_fee_cents: sum.call(:buyer_fee_cents),
      refunded_to_buyers_cents: sum.call(:refund_cents),
      platform_processing_fee_cents: sum.call(:platform_processing_fee_cents)
    }
  end

  # Settled orders with no line items (the ledger backfill skipped orders
  # with no tickets). Statements cannot include them; the page says so.
  def orders_without_items_count
    Order.excluding_test_payments.where(event_id: organization.events.select(:id), status: SETTLED_ORDER_STATUSES)
      .where.not(id: OrderItem.select(:order_id)).count
  end

  def recent_payouts
    organization.payouts.includes(:event, :settlement).order(created_at: :desc, id: :desc)
      .limit(RECENT_PAYOUT_LIMIT).map { |payout| self.class.payout_json(payout) }
  end

  # Who bore card processing on each settled order, from the order's own
  # creation-time snapshot. NULL means an order from before the snapshot,
  # when processing was deducted from organizer proceeds.
  def processing_fee_bearers
    counts = Order.excluding_test_payments.where(event_id: organization.events.select(:id), status: SETTLED_ORDER_STATUSES)
      .group(:processing_fee_bearer_snapshot).count
    { platform: counts.fetch("platform", 0), organizer: counts.fetch("organizer", 0), legacy: counts.fetch(nil, 0) }
  end
end
