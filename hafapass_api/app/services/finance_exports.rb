# frozen_string_literal: true

# Row builders for organizer finance CSVs. Amounts are integer cents; the
# controller formats them. Every figure comes from recorded order, refund,
# fee-component, settlement and payout rows, using the settlement calculator's
# processing split so an export agrees with the statement.
module FinanceExports
  SETTLED_ORDER_STATUSES = OrganizationFinanceSummary::SETTLED_ORDER_STATUSES
  BATCH_SIZE = 500

  ORDER_HEADER = %w[
    event order_reference order_date buyer_name buyer_email channel payment_method status ticket_count
    subtotal discount service_fee_paid_by_buyer service_fee_paid_by_organizer card_processing_paid_by_organizer
    card_processing_paid_by_hafapass card_processing_terms organizer_proceeds refunded_to_buyer
    refunded_organizer_proceeds net_organizer_proceeds currency
  ].freeze

  STATEMENT_HEADER = %w[
    event statement_version statement_status line occurred_at kind description order_reference amount currency
  ].freeze

  PAYOUT_HEADER = %w[
    payout_id event statement_version amount currency status provider provider_reference requested_at paid_at
    failure_message
  ].freeze

  module_function

  def channel(order)
    case order.source
    when "box_office" then "box_office"
    when "guest_list" then "guest_list"
    else "online"
    end
  end

  def processing_terms(order)
    case order.processing_fee_bearer_snapshot
    when "platform" then "hafapass_covers_tickets"
    when "organizer" then "organizer"
    else "organizer_earlier_terms"
    end
  end

  # Yields one row hash (amounts in cents) per settled order, event by event,
  # loading orders in batches.
  def each_order_row(events)
    return enum_for(:each_order_row, events) unless block_given?

    events.each do |event|
      processing = Settlements::Calculator.new(event).processing_by_order
      timezone = ActiveSupport::TimeZone[event.timezone.to_s] || Time.zone
      event.orders.where(status: SETTLED_ORDER_STATUSES)
        .includes(:order_items, refunds: :refund_items)
        .find_each(batch_size: BATCH_SIZE) do |order|
        yield order_row(event, order, processing.fetch(order.id, [0, 0]), timezone)
      end
    end
  end

  def order_row(event, order, processing, timezone)
    platform_processing, organizer_processing = processing
    items = order.order_items
    succeeded = order.refunds.select(&:succeeded?)
    proceeds = items.sum(&:organizer_proceeds_cents)
    refunded_proceeds = succeeded.flat_map(&:refund_items).sum(&:organizer_proceeds_cents)
    {
      event: event.title,
      order_reference: order.reference,
      order_date: (order.completed_at || order.created_at)&.in_time_zone(timezone)&.iso8601,
      buyer_name: order.buyer_name,
      buyer_email: order.buyer_email,
      channel: channel(order),
      payment_method: order.payment_method.presence || (order.total_cents.zero? ? "none" : "online_payment"),
      status: order.status,
      ticket_count: items.select(&:item_ticket?).sum(&:quantity),
      subtotal: order.subtotal_cents,
      discount: order.discount_cents,
      service_fee_paid_by_buyer: order.service_fee_cents,
      service_fee_paid_by_organizer: order.organizer_fee_cents,
      card_processing_paid_by_organizer: organizer_processing,
      card_processing_paid_by_hafapass: platform_processing,
      card_processing_terms: processing_terms(order),
      organizer_proceeds: proceeds,
      refunded_to_buyer: succeeded.sum(&:amount_cents),
      refunded_organizer_proceeds: refunded_proceeds,
      net_organizer_proceeds: proceeds - refunded_proceeds - organizer_processing,
      currency: order.currency.upcase
    }
  end

  ORDER_MONEY_COLUMNS = %i[
    subtotal discount service_fee_paid_by_buyer service_fee_paid_by_organizer card_processing_paid_by_organizer
    card_processing_paid_by_hafapass organizer_proceeds refunded_to_buyer refunded_organizer_proceeds
    net_organizer_proceeds
  ].freeze

  def money(cents)
    return nil if cents.nil?

    format("%<sign>s%<units>d.%<cents>02d", sign: cents.negative? ? "-" : "", units: cents.abs / 100, cents: cents.abs % 100)
  end

  def order_csv_values(row)
    ORDER_HEADER.map { |key| ORDER_MONEY_COLUMNS.include?(key.to_sym) ? money(row[key.to_sym]) : row[key.to_sym] }
  end

  STATEMENT_SUMMARY = [
    [:gross_cents, "Gross ticket sales"],
    [:discount_cents, "Discounts"],
    [:refund_cents, "Refunded to buyers"],
    [:platform_fee_cents, "HåfaPass service fees"],
    [:processing_fee_cents, "Card processing paid by organizer"],
    [:platform_processing_fee_cents, "Card processing covered by HåfaPass"],
    [:organizer_proceeds_cents, "Organizer proceeds"],
    [:reserve_cents, "Reserves held"],
    [:adjustment_cents, "Adjustments"],
    [:payable_cents, "Organizer payable"],
    [:paid_cents, "Paid out"],
    [:negative_balance_cents, "Negative balance carried forward"]
  ].freeze

  # Statement lines for a stored version (its immutable items) or, when
  # settlement is nil, the current unapproved preview.
  def statement_rows(event, settlement)
    if settlement
      items = settlement.settlement_items.order(:occurred_at, :id).map do |item|
        item.attributes.symbolize_keys.slice(:kind, :amount_cents, :description, :occurred_at, :metadata, :currency)
      end
      totals = settlement.attributes.symbolize_keys
      version = settlement.version
      status = settlement.status
    else
      result = Settlements::Calculator.call(event)
      items = result.items
      totals = result.attributes
      version = "current"
      status = "preview"
    end
    timezone = ActiveSupport::TimeZone[event.timezone.to_s] || Time.zone
    references = order_references(items)
    currency = (totals[:currency] || event.organization.currency).upcase
    lines = items.map do |item|
      order_id = item[:metadata].to_h.with_indifferent_access[:order_id]
      [event.title, version, status, "item", item[:occurred_at]&.in_time_zone(timezone)&.iso8601, item[:kind],
        item[:description], references[order_id], money(item[:amount_cents]), currency]
    end
    summary = STATEMENT_SUMMARY.map do |key, label|
      [event.title, version, status, "total", nil, key.to_s.delete_suffix("_cents"), label, nil, money(totals[key]),
        currency]
    end
    lines + summary
  end

  def order_references(items)
    ids = items.filter_map { |item| item[:metadata].to_h.with_indifferent_access[:order_id] }.uniq
    Order.where(id: ids).pluck(:id, :reference).to_h
  end

  def each_payout_row(payouts)
    return enum_for(:each_payout_row, payouts) unless block_given?

    payouts.includes(:event, :settlement).find_each(batch_size: BATCH_SIZE, order: :desc) do |payout|
      yield [payout.id, payout.event.title, payout.settlement.version, money(payout.amount_cents), payout.currency.upcase,
        payout.status, payout.provider, payout.provider_payout_id, (payout.initiated_at || payout.created_at)&.iso8601,
        payout.paid_at&.iso8601, payout.failure_message]
    end
  end
end
