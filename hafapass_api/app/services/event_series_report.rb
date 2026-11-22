# frozen_string_literal: true

require "set"

# Read-only financial and attendance report for an EventSeries.
# Every per-event financial metric reconciles to the exact cent with
# Settlements::Calculator and OrganizationFinanceSummary without mutating
# settlements, payouts, or the single-payee ledger.
class EventSeriesReport
  SETTLED_ORDER_STATUSES = OrganizationFinanceSummary::SETTLED_ORDER_STATUSES
  IN_FLIGHT_PAYOUT_STATUSES = OrganizationFinanceSummary::IN_FLIGHT_PAYOUT_STATUSES
  CASH_CUSTODY_KINDS = OrganizationFinanceSummary::CASH_CUSTODY_KINDS
  EARNING_COLUMNS = OrganizationFinanceSummary::EARNING_COLUMNS

  DEFAULT_REVENUE_SHARE_BPS = 1600
  DEFAULT_REVENUE_SHARE_LABEL = "Revenue Share"
  DEFAULT_PRIMARY_SHARE_LABEL = "Primary Organizer"
  CHECK_REFERENCE_PATTERN = "CHK-<check_number>-E<event_id>"

  ADMISSIONS_ROLES = %w[regular_night championship_night pass_sale].freeze
  REGISTRATION_ROLES = %w[registration].freeze
  OTHER_ROLES = %w[other].freeze

  SUMMED_MONEY_KEYS = %i[
    gross_cents
    discount_cents
    refund_cents
    platform_fee_cents
    processing_fee_cents
    platform_processing_fee_cents
    organizer_proceeds_cents
    sales_cents
    item_discount_cents
    absorbed_fee_cents
    refunded_proceeds_cents
    buyer_fee_cents
    door_cash_retained_cents
    reserve_cents
    other_adjustment_cents
    balance_cents
    payable_cents
    paid_cents
    in_flight_cents
    held_cents
    unresolved_buyer_liability_cents
    owed_cents
    negative_balance_cents
    requestable_cents
  ].freeze

  SUMMED_TICKET_KEYS = %i[
    tickets_issued_count
    direct_paid_tickets_count
    free_tickets_count
    pass_child_tickets_count
    checked_in_count
  ].freeze

  CHANNEL_DEFINITIONS = [
    [:online_stripe, "Online (Stripe)"],
    [:door_cash, "Door Cash"],
    [:free_comp, "Free / Comp"]
  ].freeze

  def self.call(event_series)
    new(event_series).call
  end

  def initialize(event_series)
    @event_series = event_series
    @organization = event_series.organization
  end

  def call
    memberships = ordered_memberships
    events = memberships.map(&:event)
    event_ids = events.map(&:id)

    preload_series_data(event_ids)

    rows = memberships.map { |membership| build_event_row(membership) }
    groups = build_groups(rows)
    channels = build_channels(event_ids)
    ticket_types = build_ticket_type_breakdown(memberships)
    admissions_event_ids = memberships.select { |m| ADMISSIONS_ROLES.include?(m.role) }.map(&:event_id).to_set
    revenue_share = build_revenue_share(groups, admissions_event_ids)
    closeout_checklist = build_closeout_checklist(rows, groups[:combined])

    {
      series: {
        id: event_series.id,
        organization_id: event_series.organization_id,
        name: event_series.name,
        slug: event_series.slug,
        description: event_series.description,
        status: event_series.status,
        revenue_share_bps: event_series.revenue_share_bps,
        revenue_share_base: event_series.revenue_share_base,
        revenue_share_includes_door_cash: event_series.revenue_share_includes_door_cash,
        revenue_share_label: event_series.revenue_share_label,
        primary_share_label: event_series.primary_share_label,
        events_count: rows.size
      },
      organization: {
        id: organization.id,
        name: organization.name,
        slug: organization.slug,
        timezone: organization.timezone
      },
      currency: organization.currency,
      groups: groups,
      channels: channels,
      revenue_share: revenue_share,
      closeout_checklist: closeout_checklist,
      events: rows,
      ticket_types: ticket_types,
      generated_at: Time.current
    }
  end

  private

  attr_reader :event_series, :organization

  def ordered_memberships
    event_series.event_series_memberships
      .joins(:event)
      .includes(:event)
      .order(Arel.sql("event_series_memberships.position ASC, events.starts_at ASC NULLS LAST, events.id ASC"))
      .to_a
  end

  def preload_series_data(event_ids)
    @latest_settlements = latest_settlements(event_ids)
    @payouts = organization.payouts.where(event_id: event_ids).group(:event_id, :status).sum(:amount_cents)
    @sales = item_sales(event_ids)
    @refunded_proceeds = refunded_proceeds(event_ids)
    @buyer_fees = Order.excluding_test_payments
      .where(event_id: event_ids, status: SETTLED_ORDER_STATUSES)
      .group(:event_id)
      .sum(:service_fee_cents)

    @settled_orders = Order.excluding_test_payments
      .where(event_id: event_ids, status: SETTLED_ORDER_STATUSES)
      .order(:id)
      .to_a
    @settled_order_ids = @settled_orders.map(&:id)
    @settled_orders_by_id = @settled_orders.index_by(&:id)

    @cash_order_ids = compute_cash_order_ids
    @order_items = OrderItem.where(order_id: @settled_order_ids)
      .includes(:ticket_type, :pricing_tier)
      .order(:id)
      .to_a
    @order_items_by_id = @order_items.index_by(&:id)
    @order_items_by_order_id = @order_items.group_by(&:order_id)

    @succeeded_refunds = Refund.succeeded.where(order_id: @settled_order_ids).order(:id).to_a
    @succeeded_refunds_by_order_id = @succeeded_refunds.group_by(&:order_id)
    @refund_items = RefundItem.where(refund_id: @succeeded_refunds.map(&:id)).order(:id).to_a
    @refund_items_by_order_item_id = @refund_items.group_by(&:order_item_id)
    @refund_order_ids = @succeeded_refunds.to_h { |refund| [refund.id, refund.order_id] }

    @non_cancelled_tickets = Ticket.where(event_id: event_ids, order_id: @settled_order_ids)
      .where.not(status: :cancelled)
      .includes(:ticket_type, :pricing_tier)
      .order(:id)
      .to_a
    @tickets_by_event_id = @non_cancelled_tickets.group_by(&:event_id)
    @tickets_by_order_id = @non_cancelled_tickets.group_by(&:order_id)
  end

  def compute_cash_order_ids
    return Set.new if @settled_order_ids.empty?

    direct_cash = @settled_orders.select { |order| order.payment_method == "door_cash" }.map(&:id)
    payment_cash = Payment.where(order_id: @settled_order_ids, provider: "door_cash").pluck(:order_id)
    Set.new(direct_cash + payment_cash)
  end

  def latest_settlements(event_ids)
    return {} if event_ids.empty?

    Settlement.where(event_id: event_ids)
      .select("DISTINCT ON (event_id) settlements.*")
      .order(:event_id, version: :desc)
      .index_by(&:event_id)
  end

  def item_sales(event_ids)
    return {} if event_ids.empty?

    OrderItem.joins(:order)
      .where(orders: { event_id: event_ids, status: SETTLED_ORDER_STATUSES })
      .merge(Order.excluding_test_payments)
      .group("orders.event_id")
      .pluck(Arel.sql("orders.event_id, SUM(order_items.subtotal_cents), SUM(order_items.discount_cents)"))
      .to_h { |event_id, subtotal, discount| [event_id, [subtotal.to_i, discount.to_i]] }
  end

  def refunded_proceeds(event_ids)
    return {} if event_ids.empty?

    RefundItem.joins(refund: :order)
      .where(refunds: { status: Refund.statuses[:succeeded] }, orders: { event_id: event_ids, status: SETTLED_ORDER_STATUSES })
      .merge(Order.excluding_test_payments)
      .group("orders.event_id")
      .sum(:organizer_proceeds_cents)
  end

  def build_event_row(membership)
    event = membership.event
    settlement = @latest_settlements[event.id]
    result = Settlements::Calculator.call(event)
    preview = result.attributes

    paid = @payouts.fetch([event.id, "paid"], 0)
    in_flight = IN_FLIGHT_PAYOUT_STATUSES.sum { |status| @payouts.fetch([event.id, status.to_s], 0) }
    held = @payouts.fetch([event.id, "held"], 0)
    recovery = paid.positive? ? RefundReconciliationQueue.recovery_amount_for_event(event) : 0

    balance = preview[:organizer_proceeds_cents] - preview[:processing_fee_cents] - preview[:reserve_cents] +
      preview[:adjustment_cents] - recovery
    owed = [balance - paid - in_flight - held, 0].max
    sales, item_discounts = @sales.fetch(event.id, [0, 0])
    refunded = @refunded_proceeds.fetch(event.id, 0)
    cash = door_cash_retained(result.items)
    statement_current = statement_current?(settlement, preview)
    payable_version = settlement&.status_finalized? && settlement.source_digest == preview[:source_digest]
    requestable = payable_version ? [settlement.available_to_payout_cents, owed].min : 0
    awaiting_completion = event.published? && event.ends_at.present? && event.ends_at <= Time.current
    s_state = settlement_state(settlement, statement_current)
    p_state = payout_state(
      owed: owed,
      in_flight: in_flight,
      held: held,
      paid: paid,
      requestable: requestable,
      finalized: settlement&.status_finalized?
    )

    ticket_counts = compute_ticket_counts(@tickets_by_event_id.fetch(event.id, []))

    {
      event_id: event.id,
      title: event.title,
      slug: event.slug,
      status: event.status,
      starts_at: event.starts_at,
      ends_at: event.ends_at,
      timezone: event.timezone,
      role: membership.role,
      position: membership.position,
      awaiting_completion: awaiting_completion,
      gross_cents: preview[:gross_cents],
      discount_cents: preview[:discount_cents],
      refund_cents: preview[:refund_cents],
      platform_fee_cents: preview[:platform_fee_cents],
      processing_fee_cents: preview[:processing_fee_cents],
      platform_processing_fee_cents: preview[:platform_processing_fee_cents],
      organizer_proceeds_cents: preview[:organizer_proceeds_cents],
      sales_cents: sales,
      item_discount_cents: item_discounts,
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
      unresolved_buyer_liability_cents: recovery,
      owed_cents: owed,
      negative_balance_cents: [paid - balance, 0].max,
      requestable_cents: requestable,
      settlement: settlement && {
        id: settlement.id,
        version: settlement.version,
        status: settlement.status,
        finalized_at: settlement.finalized_at,
        current: statement_current,
        payable: payable_version,
        available_to_payout_cents: settlement.available_to_payout_cents
      },
      settlement_state: s_state,
      payout_state: p_state,
      closeout_note: closeout_note_for_event(
        event_id: event.id,
        awaiting_completion: awaiting_completion,
        settlement_state: s_state,
        payout_state: p_state,
        reserve_cents: preview[:reserve_cents],
        owed_cents: owed
      )
    }.merge(ticket_counts)
  end

  def compute_ticket_counts(tickets)
    has_parent_column = ticket_has_parent_column?
    direct_paid = 0
    free = 0
    pass_child = 0
    checked_in = 0

    tickets.each do |ticket|
      checked_in += 1 if ticket.checked_in?

      if has_parent_column && ticket.public_send(:parent_ticket_id).present?
        pass_child += 1
      elsif ticket_paid?(ticket)
        direct_paid += 1
      else
        free += 1
      end
    end

    {
      tickets_issued_count: tickets.size,
      direct_paid_tickets_count: direct_paid,
      free_tickets_count: free,
      pass_child_tickets_count: pass_child,
      checked_in_count: checked_in
    }
  end

  def ticket_has_parent_column?
    return @ticket_has_parent_column unless @ticket_has_parent_column.nil?

    @ticket_has_parent_column = Ticket.column_names.include?("parent_ticket_id")
  end

  def ticket_paid?(ticket)
    item = ticket.order_item_id ? @order_items_by_id[ticket.order_item_id] : nil
    if item
      (item.subtotal_cents - item.discount_cents + item.fee_cents + item.tax_cents).positive?
    else
      order = @settled_orders_by_id[ticket.order_id]
      order ? order.total_cents.positive? : false
    end
  end

  def build_groups(rows)
    {
      admissions: summarize_group(rows.select { |row| ADMISSIONS_ROLES.include?(row[:role]) }),
      registration: summarize_group(rows.select { |row| REGISTRATION_ROLES.include?(row[:role]) }),
      other: summarize_group(rows.select { |row| OTHER_ROLES.include?(row[:role]) }),
      combined: summarize_group(rows)
    }
  end

  def summarize_group(rows)
    summary = { events_count: rows.size }
    SUMMED_MONEY_KEYS.each do |key|
      summary[key] = rows.sum { |row| row[key] }
    end
    SUMMED_TICKET_KEYS.each do |key|
      summary[key] = rows.sum { |row| row[key] }
    end
    summary
  end

  def build_channels(_event_ids)
    buckets = CHANNEL_DEFINITIONS.to_h do |key, label|
      [key, {
        channel: key.to_s,
        label: label,
        orders_count: 0,
        tickets_issued_count: 0,
        checked_in_count: 0,
        gross_cents: 0,
        discount_cents: 0,
        refund_cents: 0,
        organizer_proceeds_cents: 0,
        door_cash_retained_cents: 0
      }]
    end

    @settled_orders.each do |order|
      channel_key = classify_order_channel(order)
      bucket = buckets.fetch(channel_key)

      items = @order_items_by_order_id.fetch(order.id, [])
      refunds = @succeeded_refunds_by_order_id.fetch(order.id, [])
      order_refund_items = items.flat_map { |item| @refund_items_by_order_item_id.fetch(item.id, []) }
      order_tickets = @tickets_by_order_id.fetch(order.id, [])

      item_proceeds = items.sum(&:organizer_proceeds_cents)
      refunded_proceeds = order_refund_items.sum(&:organizer_proceeds_cents)
      net_proceeds = item_proceeds - refunded_proceeds

      bucket[:orders_count] += 1
      bucket[:tickets_issued_count] += order_tickets.size
      bucket[:checked_in_count] += order_tickets.count(&:checked_in?)
      bucket[:gross_cents] += order.subtotal_cents
      bucket[:discount_cents] += order.discount_cents
      bucket[:refund_cents] += refunds.sum(&:amount_cents)
      bucket[:organizer_proceeds_cents] += net_proceeds
      bucket[:door_cash_retained_cents] += net_proceeds if channel_key == :door_cash
    end

    buckets.each_value do |bucket|
      bucket[:organizer_proceeds_cents] = [bucket[:organizer_proceeds_cents], 0].max
    end

    buckets
  end

  def classify_order_channel(order)
    return :door_cash if @cash_order_ids.include?(order.id)
    return :free_comp if order.total_cents.zero?

    :online_stripe
  end

  def build_ticket_type_breakdown(memberships)
    membership_by_event_id = memberships.index_by(&:event_id)
    event_order_index = memberships.each_with_index.to_h { |membership, idx| [membership.event_id, idx] }

    buckets = {}

    @order_items.each do |item|
      next unless item.item_ticket? && item.ticket_type_id.present?

      order = @settled_orders_by_id[item.order_id]
      next unless order

      membership = membership_by_event_id[order.event_id]
      next unless membership

      key = [order.event_id, item.ticket_type_id, item.pricing_tier_id]
      bucket = buckets[key] ||= init_ticket_type_bucket(
        membership: membership,
        ticket_type: item.ticket_type,
        pricing_tier: item.pricing_tier,
        tier_name: item.tier_name,
        fallback_name: item.name,
        fallback_price_cents: item.unit_price_cents
      )

      refunded_proceeds = @refund_items_by_order_item_id.fetch(item.id, []).sum(&:organizer_proceeds_cents)
      bucket[:gross_cents] += item.subtotal_cents
      bucket[:discount_cents] += item.discount_cents
      bucket[:refunded_proceeds_cents] += refunded_proceeds
      bucket[:raw_proceeds_cents] += item.organizer_proceeds_cents
    end

    @non_cancelled_tickets.each do |ticket|
      membership = membership_by_event_id[ticket.event_id]
      next unless membership

      item = ticket.order_item_id ? @order_items_by_id[ticket.order_item_id] : nil
      if item
        ticket_type_id = item.ticket_type_id
        ticket_type = item.ticket_type
        pricing_tier_id = item.pricing_tier_id
        pricing_tier = item.pricing_tier
      else
        ticket_type_id = ticket.ticket_type_id
        ticket_type = ticket.ticket_type
        pricing_tier_id = ticket.pricing_tier_id
        pricing_tier = ticket.pricing_tier
      end
      key = [ticket.event_id, ticket_type_id, pricing_tier_id]

      bucket = buckets[key] ||= init_ticket_type_bucket(
        membership: membership,
        ticket_type: ticket_type,
        pricing_tier: pricing_tier,
        tier_name: item&.tier_name,
        fallback_name: item&.name || ticket_type&.name || "Ticket",
        fallback_price_cents: pricing_tier&.price_cents || item&.unit_price_cents || ticket_type&.price_cents || 0
      )

      bucket[:tickets_issued_count] += 1
      bucket[:checked_in_count] += 1 if ticket.checked_in?
    end

    buckets.values
      .sort_by { |row| [event_order_index.fetch(row[:event_id], 0), row[:ticket_type_name].to_s.downcase, row[:pricing_tier_name].to_s.downcase, row[:ticket_type_id].to_i] }
      .map do |row|
        raw_proceeds = row[:raw_proceeds_cents]
        row.except(:raw_proceeds_cents).merge(
          organizer_proceeds_cents: [raw_proceeds - row[:refunded_proceeds_cents], 0].max
        )
      end
  end

  def init_ticket_type_bucket(membership:, ticket_type:, pricing_tier:, tier_name:, fallback_name:, fallback_price_cents:)
    {
      event_id: membership.event_id,
      event_title: membership.event.title,
      role: membership.role,
      ticket_type_id: ticket_type&.id,
      ticket_type_name: ticket_type&.name || fallback_name,
      pricing_tier_id: pricing_tier&.id,
      pricing_tier_name: pricing_tier&.name || tier_name,
      price_cents: pricing_tier&.price_cents || fallback_price_cents || ticket_type&.price_cents || 0,
      tickets_issued_count: 0,
      checked_in_count: 0,
      gross_cents: 0,
      discount_cents: 0,
      refunded_proceeds_cents: 0,
      raw_proceeds_cents: 0,
      organizer_proceeds_cents: 0
    }
  end

  def build_revenue_share(groups, admissions_event_ids)
    bps = event_series.revenue_share_bps.nil? ? DEFAULT_REVENUE_SHARE_BPS : event_series.revenue_share_bps
    primary_bps = 10_000 - bps
    base_mode = event_series.revenue_share_base.presence || "admissions_net_proceeds"
    includes_door_cash = event_series.revenue_share_includes_door_cash

    admissions = groups[:admissions]
    combined = groups[:combined]

    raw_base_cents, scope_door_cash_deduction_cents, scope_door_cash_retained_cents = case base_mode
    when "admissions_gross"
      [
        [admissions[:gross_cents] - admissions[:discount_cents] - admissions[:refund_cents], 0].max,
        admissions_door_cash_gross_cents(admissions_event_ids),
        admissions[:door_cash_retained_cents]
      ]
    when "admissions_net_after_processing"
      [
        [admissions[:organizer_proceeds_cents] - admissions[:processing_fee_cents], 0].max,
        admissions[:door_cash_retained_cents],
        admissions[:door_cash_retained_cents]
      ]
    when "all_net_proceeds"
      [
        combined[:organizer_proceeds_cents],
        combined[:door_cash_retained_cents],
        combined[:door_cash_retained_cents]
      ]
    else # "admissions_net_proceeds"
      [
        admissions[:organizer_proceeds_cents],
        admissions[:door_cash_retained_cents],
        admissions[:door_cash_retained_cents]
      ]
    end

    base_cents = includes_door_cash ? [raw_base_cents, 0].max : [raw_base_cents - scope_door_cash_deduction_cents, 0].max
    share_cents, primary_cents = allocate_revenue_share(base_cents, bps)

    {
      revenue_share_bps: bps,
      primary_share_bps: primary_bps,
      revenue_share_label: event_series.revenue_share_label.presence || DEFAULT_REVENUE_SHARE_LABEL,
      primary_share_label: event_series.primary_share_label.presence || DEFAULT_PRIMARY_SHARE_LABEL,
      revenue_share_base: base_mode,
      revenue_share_includes_door_cash: includes_door_cash,
      base_cents: base_cents,
      share_cents: share_cents,
      primary_cents: primary_cents,
      door_cash_retained_cents: combined[:door_cash_retained_cents],
      scope_door_cash_retained_cents: scope_door_cash_retained_cents,
      net_platform_payable_cents: combined[:payable_cents],
      paid_cents: combined[:paid_cents],
      owed_cents: combined[:owed_cents],
      reserve_cents: combined[:reserve_cents]
    }
  end

  def admissions_door_cash_gross_cents(admissions_event_ids)
    return 0 if admissions_event_ids.empty?

    subtotal = 0
    discount = 0
    refund = 0

    @settled_orders.each do |order|
      next unless admissions_event_ids.include?(order.event_id)
      next unless @cash_order_ids.include?(order.id)

      subtotal += order.subtotal_cents
      discount += order.discount_cents
      refund += @succeeded_refunds_by_order_id.fetch(order.id, []).sum(&:amount_cents)
    end

    [subtotal - discount - refund, 0].max
  end

  def allocate_revenue_share(base_cents, revenue_share_bps)
    return [0, 0] if base_cents <= 0

    share_cents = (base_cents * revenue_share_bps + 5_000).div(10_000)
    [share_cents, base_cents - share_cents]
  end

  def build_closeout_checklist(rows, combined)
    {
      events_total: rows.size,
      awaiting_completion_count: rows.count { |row| row[:awaiting_completion] },
      not_finalized_count: rows.count { |row| row[:settlement_state] == "not_finalized" },
      changed_since_finalization_count: rows.count { |row| row[:settlement_state] == "changed" },
      ready_for_payout_count: rows.count { |row| row[:payout_state] == "ready" },
      paid_count: rows.count { |row| row[:payout_state] == "paid" },
      active_reserve_count: rows.count { |row| row[:reserve_cents].positive? },
      total_reserve_cents: combined[:reserve_cents],
      total_owed_cents: combined[:owed_cents],
      check_reference_pattern: CHECK_REFERENCE_PATTERN,
      guidance: "Finalize each completed event's settlement statement individually, issue check payouts using " \
        "#{CHECK_REFERENCE_PATTERN}, and release any 30-day reserve holdbacks after the dispute window closes. " \
        "Door cash stays in organizer custody and is excluded from platform payouts."
    }
  end

  def closeout_note_for_event(event_id:, awaiting_completion:, settlement_state:, payout_state:, reserve_cents:, owed_cents:)
    return "Mark event completed so its settlement statement can be finalized." if awaiting_completion
    return "Finalize a new settlement version to capture recent activity before requesting payout." if settlement_state == "changed"
    return "Settlement finalized and ready for payout (use reference CHK-<num>-E#{event_id})." if payout_state == "ready"
    return "Payout in progress; confirm check clearance and reference CHK-<num>-E#{event_id}." if payout_state == "in_progress"
    return "Payout on hold while cancellation refunds are being resolved." if payout_state == "on_hold"
    if payout_state == "paid"
      return reserve_cents.positive? ? "Paid out; reserve holdback remains pending 30-day release." : "Settled and paid in full."
    end
    return "Finalize statement once the event concludes to unlock payout." if settlement_state == "not_finalized" && owed_cents.positive?
    return "Reserve holdback active; release after 30-day post-event window." if reserve_cents.positive?

    "No payout balance currently owed."
  end

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

  def settlement_state(settlement, statement_current)
    return "not_finalized" unless settlement&.status_finalized?

    statement_current ? "finalized" : "changed"
  end

  def payout_state(owed:, in_flight:, held:, paid:, requestable:, finalized:)
    return "on_hold" if held.positive?
    return "in_progress" if in_flight.positive?
    if owed.positive?
      return "ready" if requestable.positive?

      return finalized ? "needs_new_version" : "awaiting_statement"
    end

    paid.positive? ? "paid" : "nothing_owed"
  end
end
