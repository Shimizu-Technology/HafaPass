# frozen_string_literal: true

# Group recorded line items by price paid, retaining historical prices even
# when an organizer has since changed the base price. Shared order totals
# come from the same ledger used by the existing finance report.
class EventReportSales
  MONEY_FIELDS = %i[gross_cents discount_cents fee_cents tax_cents refund_cents organizer_proceeds_cents].freeze
  TICKET_STATUSES = %w[issued checked_in not_checked_in transferred cancelled].freeze

  def initialize(event:, orders:, ticket_type_id:, status:)
    @event = event
    @type_id = ticket_type_id
    @ticket_status = status if TICKET_STATUSES.include?(status)
    @orders = case status
    when nil, *TICKET_STATUSES then orders
    when "paid" then orders.where(status: EventReportingService::ACTIVE_ORDER_STATUSES)
    else orders.where(status: status)
    end
    @rows = {}
    @matching_orders = 0
    @issued_count = 0
  end

  def call
    @orders.preload(:order_items, :refunds, tickets: :pricing_tier).find_in_batches do |orders|
      items = orders.flat_map(&:order_items)
      # Only the sale's own refunds (Refund.on_sale): payment B's refunds on
      # an order payment A fulfilled never reduce A's tier rows.
      @sale_refund_ids = Refund.succeeded.on_sale.where(order_id: orders.map(&:id)).pluck(:id).to_set
      refunds = RefundItem.where(order_item_id: items.map(&:id), refund_id: @sale_refund_ids.to_a).group_by(&:order_item_id)
      selected = RefundTicket.active.where(refund_id: @sale_refund_ids.to_a).pluck(:ticket_id, :amount_cents).to_h
      checks = @event.tickets.where(parent_ticket_id: orders.flat_map { |order| order.tickets.map(&:id) }, status: :checked_in)
        .pluck(:parent_ticket_id).to_set
      orders.each { |order| add_order(order, refunds, selected, checks) }
    end

    capacity = remaining_capacity
    rows = @rows.values.sort_by { |row| [row[:ticket_type_name].downcase, row[:ticket_type_id], row[:unit_price_cents], row[:tier_name]] }
    rows.each do |row|
      row[:remaining_capacity] = capacity.fetch(row[:ticket_type_id])
      row[:net_cents] = row[:gross_cents] - row[:discount_cents] + row[:fee_cents] + row[:tax_cents] - row[:refund_cents]
      row[:no_show_count] = row[:tickets_sold] - row[:tickets_refunded_or_cancelled] - row[:checked_in_count]
    end
    ledger = @type_id || @ticket_status ? sum_rows(rows) : Commerce::LedgerTotals.call(@orders)
    [rows, { gross_sales_cents: ledger[:gross_cents], net_sales_cents: ledger[:net_cents],
      total_refunded_cents: ledger[:refund_cents], discount_cents: ledger[:discount_cents] }, @matching_orders, @issued_count]
  end

  private

  def types
    @types ||= @event.ticket_types.index_by(&:id)
  end

  def remaining_capacity
    ids = types.keys
    holds = InventoryHold.current.where(ticket_type_id: ids).group(:ticket_type_id).sum(:quantity)
    waitlist = WaitlistOffer.holding_inventory.where(ticket_type_id: ids).group(:ticket_type_id).sum(:quantity)
    seats = SeatHold.status_active.joins(:seat_hold_session, :event_seat).where(event_seats: { ticket_type_id: ids })
      .where(seat_hold_sessions: { status: SeatHoldSession.statuses[:active] })
      .where("seat_hold_sessions.expires_at > ?", Time.current).group("event_seats.ticket_type_id").count
    types.transform_values do |type|
      id = type.id
      [type.quantity_available - type.quantity_sold - holds.fetch(id, 0) - waitlist.fetch(id, 0) - seats.fetch(id, 0), 0].max
    end
  end

  def add_order(order, refunds, selected, checks)
    tickets = order.tickets.select { |ticket| ticket.event_id == @event.id && !ticket.pass_child? }.sort_by(&:id)
    linked = tickets.group_by(&:order_item_id)
    added = false
    order.order_items.each do |item|
      next unless item.item_ticket? && type_included?(item.ticket_type_id)

      group = linked.fetch(item.id, [])
      indices = matching_indices(group, order, selected)
      next if @ticket_status && indices.empty?

      refund_items = refunds.fetch(item.id, [])
      money = [item.subtotal_cents, item.discount_cents, item.fee_cents, item.tax_cents,
        refund_items.sum(&:amount_cents), item.organizer_proceeds_cents - refund_items.sum(&:organizer_proceeds_cents)]
      tier_name = item.tier_name.presence || group.first&.pricing_tier&.name
      row = bucket(item.ticket_type_id, item.pricing_tier_id, tier_name, item.unit_price_cents)
      if @ticket_status
        add_money(row, allocated_money(money, group, indices, selected))
      else
        add_money(row, money)
      end
      row[:tickets_sold] += @ticket_status ? indices.length : item.quantity
      add_tickets(row, group.values_at(*indices), order, selected, checks)
      added = true
    end
    legacy = linked.fetch(nil, [])
    if legacy.any?
      legacy_indices = matching_indices(legacy, order, selected)
      add_legacy_tickets(order, legacy, legacy_indices, refunds, selected, checks)
      added ||= legacy_indices.any? { |index| type_included?(legacy[index].ticket_type_id) }
    end
    @matching_orders += 1 if added || (!@type_id && !@ticket_status)
  end

  def type_included?(id)
    types.key?(id) && (!@type_id || @type_id == id)
  end

  def matching_indices(tickets, order, selected)
    tickets.each_index.select do |index|
      ticket = tickets[index]
      case @ticket_status
      when nil then true
      when "cancelled" then cancelled?(ticket, order, selected)
      when "not_checked_in" then ticket.issued? && !cancelled?(ticket, order, selected)
      else ticket.status == @ticket_status && !cancelled?(ticket, order, selected)
      end
    end
  end

  def cancelled?(ticket, order, selected)
    ticket.cancelled? || order.refunded? || selected.key?(ticket.id)
  end

  def bucket(type_id, tier_id, label, price)
    type = types.fetch(type_id)
    label ||= tier_id ? "Price window" : "Base price"
    @rows[[type_id, tier_id, price]] ||= MONEY_FIELDS.index_with(0).merge(
      ticket_type_id: type_id, ticket_type_name: type.name, pricing_tier_id: tier_id, tier_name: label,
      unit_price_cents: price, tickets_sold: 0, tickets_refunded_or_cancelled: 0, checked_in_count: 0
    )
  end

  def add_tickets(row, tickets, order, selected, checks)
    @issued_count += tickets.length
    tickets.each do |ticket|
      if cancelled?(ticket, order, selected)
        row[:tickets_refunded_or_cancelled] += 1
      elsif ticket.checked_in? || checks.include?(ticket.id)
        row[:checked_in_count] += 1
      end
    end
  end

  def add_money(row, money)
    MONEY_FIELDS.zip(money).each { |field, value| row[field] += value }
  end

  def allocated_money(money, tickets, indices, selected)
    weights = Array.new(tickets.length, 1)
    MONEY_FIELDS.zip(money).map do |field, amount|
      if field == :refund_cents
        explicit = tickets.map { |ticket| selected.fetch(ticket.id, 0) }
        residual = Commerce::MoneyAllocator.call([amount - explicit.sum, 0].max, weights)
        indices.sum { |index| explicit[index] + residual[index] }
      else
        Commerce::MoneyAllocator.call(amount, weights).values_at(*indices).sum
      end
    end
  end

  def add_legacy_tickets(order, tickets, indices, refunds, selected, checks)
    return if indices.empty?

    items = order.order_items
    subtotal = order.subtotal_cents - items.sum(&:subtotal_cents)
    discount = order.discount_cents - items.sum(&:discount_cents)
    fees = order.total_cents - order.subtotal_cents + order.discount_cents - items.sum { |item| item.fee_cents + item.tax_cents }
    sale_refunds = order.refunds.select { |refund| @sale_refund_ids.include?(refund.id) }
    refunded = sale_refunds.sum(&:amount_cents) - items.sum { |item| refunds.fetch(item.id, []).sum(&:amount_cents) }
    money = [subtotal, discount, fees, 0, refunded, 0].map { |cents| [cents, 0].max }

    indices.select { |index| type_included?(tickets[index].ticket_type_id) }.group_by do |index|
      ticket = tickets[index]
      type = types.fetch(ticket.ticket_type_id)
      bucket(type.id, ticket.pricing_tier_id, ticket.pricing_tier&.name, ticket.pricing_tier&.price_cents || type.price_cents || 0)
    end.each do |row, matching|
      add_money(row, allocated_money(money, tickets, matching, selected))
      row[:tickets_sold] += matching.length
      add_tickets(row, tickets.values_at(*matching), order, selected, checks)
    end
  end

  def sum_rows(rows)
    %i[gross_cents net_cents refund_cents discount_cents].index_with { |key| rows.sum { |row| row[key] } }
  end
end
