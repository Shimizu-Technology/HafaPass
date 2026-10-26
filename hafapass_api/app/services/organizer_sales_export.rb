# frozen_string_literal: true

require "csv"

# Ticket amounts are allocations of recorded order-item cents. Total paid is
# ticket price minus discount plus fee and tax, before any later refund.
class OrganizerSalesExport
  COLUMNS = {
    "name" => "Name", "email" => "Email", "phone" => "Phone", "order_number" => "Order #",
    "ticket_type" => "Ticket type", "ticket_price" => "Ticket price", "discount" => "Discount",
    "fee" => "Fee", "tax" => "Tax", "total_paid" => "Total paid",
    "price_paid" => "Total paid", "discount_promo" => "Discount / promo",
    "channel" => "Channel", "status" => "Status", "check_in_time" => "Check-in time",
    "transferred_to" => "Transferred to", "purchase_date" => "Purchase date",
    "notes_custom_answers" => "Registration answers"
  }.freeze
  DEFAULT_COLUMNS = %w[name email order_number ticket_type total_paid channel status check_in_time purchase_date].freeze
  TRANSACTION_COLUMNS = %w[order_number ticket_type ticket_price discount fee tax total_paid channel status purchase_date].freeze
  FINANCE_COLUMNS = %w[ticket_price discount fee tax total_paid price_paid discount_promo].freeze
  ATTENDEE_COLUMNS = %w[name email phone check_in_time transferred_to notes_custom_answers].freeze

  def initialize(query:, columns:, finance:, attendees:)
    @query = query
    @finance = finance
    @attendees = attendees
    @columns = Array(columns).map(&:to_s).uniq.presence ||
      (attendees ? DEFAULT_COLUMNS - (finance ? [] : FINANCE_COLUMNS) : TRANSACTION_COLUMNS)
    unknown = @columns - COLUMNS.keys
    raise OrganizerSalesQuery::InvalidFilter, "Invalid columns: #{unknown.join(', ')}" if unknown.any?
    raise OrganizerSalesQuery::InvalidFilter, "Financial columns require finance access" if !finance && (@columns & FINANCE_COLUMNS).any?
    raise OrganizerSalesQuery::InvalidFilter, "Attendee columns require attendee access" if !attendees && (@columns & ATTENDEE_COLUMNS).any?
  end

  attr_reader :columns

  def header
    columns.map { |column| COLUMNS.fetch(column) }
  end

  def each_row
    return enum_for(:each_row) unless block_given?

    @query.each_batch(on_batch: method(:preload_ticket_groups)) do |record|
      yield columns.map { |column| value(record, column) }
    end
  end

  def self.local_time(value, event)
    return nil unless value

    local = value.in_time_zone(event.timezone)
    "#{value.utc.iso8601} (#{local.strftime('%Y-%m-%d %H:%M %Z')})"
  end

  private

  def value(record, column)
    ticket = record.is_a?(Ticket) ? record : nil
    order = ticket ? ticket.order : record
    item = ticket&.order_item
    case column
    when "name" then ticket&.attendee_name.presence || order.buyer_name
    when "email" then ticket&.holder_email.presence || ticket&.attendee_email.presence || order.buyer_email
    when "phone" then order.buyer_phone
    when "order_number" then order.reference
    when "ticket_type" then ticket ? ticket.ticket_type.name : order.tickets.map { |row| row.ticket_type.name }.uniq.join("; ")
    when "ticket_price" then money(ticket ? allocated(item, ticket, :subtotal_cents) : order.subtotal_cents)
    when "discount" then money(ticket ? allocated(item, ticket, :discount_cents) : order.discount_cents)
    when "fee" then money(ticket ? allocated(item, ticket, :fee_cents) : order.service_fee_cents)
    when "tax" then money(ticket ? allocated(item, ticket, :tax_cents) : order.order_items.sum(&:tax_cents))
    when "total_paid", "price_paid" then money(ticket ? ticket_total(item, ticket) : order.total_cents)
    when "discount_promo" then [money(ticket ? allocated(item, ticket, :discount_cents) : order.discount_cents), order.promo_code&.code].compact.join(" / ")
    when "channel" then FinanceExports.channel(order)
    when "status" then OrganizerTicketSalesStatus.label(ticket ?
      OrganizerTicketSalesStatus.for(ticket, event_cancelled: @query.event.cancelled?) : order.status)
    when "check_in_time" then self.class.local_time(ticket ? ticket.checked_in_at : order.tickets.filter_map(&:checked_in_at).max, @query.event)
    when "transferred_to" then transferred_to(ticket ? [ticket] : order.tickets)
    when "purchase_date" then self.class.local_time(order.completed_at || order.created_at, @query.event)
    when "notes_custom_answers" then registration_answers(order)
    end
  end

  def allocated(item, ticket, component)
    order = ticket.order
    key = [order.id, item&.id, component]
    allocations = @allocation_cache[key] ||= begin
      ticket_ids = order_ticket_groups(order).fetch(item&.id, [])
      cents = item ? item.public_send(component) : legacy_residual(order, component)
      ticket_ids.zip(Commerce::MoneyAllocator.call(cents, Array.new(ticket_ids.length, 1))).to_h
    end
    allocations.fetch(ticket.id)
  end

  def ticket_total(item, ticket)
    allocated(item, ticket, :subtotal_cents) - allocated(item, ticket, :discount_cents) +
      allocated(item, ticket, :fee_cents) + allocated(item, ticket, :tax_cents)
  end

  def order_ticket_groups(order)
    @allocation_cache.fetch([order.id, :ticket_groups])
  end

  def preload_ticket_groups(batch)
    @allocation_cache = {}
    order_ids = batch.map { |record| record.is_a?(Ticket) ? record.order_id : record.id }.uniq
    groups = Ticket.where(order_id: order_ids).order(:id).pluck(:order_id, :id, :order_item_id)
      .group_by(&:first)
    order_ids.each do |order_id|
      @allocation_cache[[order_id, :ticket_groups]] = Array(groups[order_id]).group_by(&:last)
        .transform_values { |rows| rows.map { |row| row[1] } }
    end
  end

  def legacy_residual(order, component)
    total = case component
    when :fee_cents then order.service_fee_cents
    when :tax_cents then order.total_cents - order.subtotal_cents + order.discount_cents - order.service_fee_cents
    else order.public_send(component)
    end
    linked_item_ids = order_ticket_groups(order).keys.compact
    attributed = order.order_items.sum { |item| linked_item_ids.include?(item.id) ? item.public_send(component) : 0 }
    [total - attributed, 0].max
  end

  def money(cents)
    FinanceExports.money(cents)
  end

  def registration_answers(order)
    # Keep the column key compatible with saved export requests. Internal
    # support notes have a separate audience and never belong in this export.
    order.registration_responses.map { |answer| "#{answer.prompt_snapshot}: #{answer.answer.to_json}" }.join("; ")
  end

  def transferred_to(tickets)
    tickets.filter_map { |row| row.ticket_transfers.select(&:accepted?).max_by(&:id)&.recipient_email }.uniq.join("; ")
  end
end
