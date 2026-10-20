# frozen_string_literal: true

# Read-only, organization-wide view of the same settlement math the event
# finance section uses. It never finalizes, snapshots, or changes records.
class OrganizationFinanceSummary
  SETTLED_ORDER_STATUSES = %i[completed partially_refunded refunded].freeze
  IN_FLIGHT_PAYOUT_STATUSES = %i[pending processing].freeze
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
      currency: organization.currency,
      totals: totals(rows),
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
    settled = Order.where(status: SETTLED_ORDER_STATUSES).select(:event_id)
    organization.events
      .where(id: settled).or(organization.events.where(id: organization.settlements.select(:event_id)))
      .or(organization.events.where(id: organization.payouts.select(:event_id)))
      .or(organization.events.where(id: organization.balance_adjustments.where.not(event_id: nil).select(:event_id)))
      .order(starts_at: :desc, id: :desc)
  end

  def event_rows
    events = financial_events.to_a
    latest = latest_settlements(events.map(&:id))
    payouts = organization.payouts.where(event_id: events.map(&:id)).group(:event_id, :status).sum(:amount_cents)
    events.map { |event| event_row(event, latest[event.id], payouts) }
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
    owed = [preview[:payable_cents] - paid - in_flight, 0].max
    statement_current = statement_current?(settlement, preview)
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
      door_cash_retained_cents: door_cash_retained(result.items),
      payable_cents: preview[:payable_cents],
      paid_cents: paid,
      in_flight_cents: in_flight,
      owed_cents: owed,
      negative_balance_cents: preview[:negative_balance_cents],
      settlement: settlement && {
        id: settlement.id,
        version: settlement.version,
        status: settlement.status,
        finalized_at: settlement.finalized_at,
        current: statement_current,
        available_to_payout_cents: settlement.available_to_payout_cents
      },
      settlement_state: settlement_state(settlement, statement_current),
      payout_state: payout_state(owed: owed, in_flight: in_flight, paid: paid, settlement: settlement,
        statement_current: statement_current)
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

  def payout_state(owed:, in_flight:, paid:, settlement:, statement_current:)
    return "in_progress" if in_flight.positive?
    if owed.positive?
      return "ready" if statement_current && settlement.available_to_payout_cents.positive?

      return "awaiting_statement"
    end
    paid.positive? ? "paid" : "nothing_owed"
  end

  def totals(rows)
    sum = ->(key) { rows.sum { |row| row[key] } }
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
      owed_cents: sum.call(:owed_cents),
      negative_balance_cents: sum.call(:negative_balance_cents),
      available_to_payout_cents: OrganizationPayoutBalance.available_cents(organization)
    }
  end

  def recent_payouts
    organization.payouts.includes(:event, :settlement).order(created_at: :desc, id: :desc)
      .limit(RECENT_PAYOUT_LIMIT).map { |payout| self.class.payout_json(payout) }
  end

  # Who bore card processing on each settled order, from the order's own
  # creation-time snapshot. NULL means an order from before the snapshot,
  # when processing was deducted from organizer proceeds.
  def processing_fee_bearers
    counts = Order.where(event_id: organization.events.select(:id), status: SETTLED_ORDER_STATUSES)
      .group(:processing_fee_bearer_snapshot).count
    { platform: counts.fetch("platform", 0), organizer: counts.fetch("organizer", 0), legacy: counts.fetch(nil, 0) }
  end
end
