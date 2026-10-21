# frozen_string_literal: true

require "csv"

class OrganizerSalesExport
  COLUMNS = {
    "name" => "Name", "email" => "Email", "phone" => "Phone", "order_number" => "Order #",
    "ticket_type" => "Ticket type", "price_paid" => "Price paid", "fee" => "Fee",
    "discount_promo" => "Discount / promo", "channel" => "Channel", "status" => "Status",
    "check_in_time" => "Check-in time", "transferred_to" => "Transferred to",
    "purchase_date" => "Purchase date", "notes_custom_answers" => "Notes / custom answers"
  }.freeze
  DEFAULT_COLUMNS = %w[name email order_number ticket_type price_paid channel status check_in_time purchase_date].freeze
  FINANCE_COLUMNS = %w[price_paid fee discount_promo].freeze
  CONTACT_COLUMNS = %w[email phone transferred_to notes_custom_answers].freeze
  SENSITIVE_COLUMNS = %w[phone notes_custom_answers].freeze

  def initialize(query:, columns:, finance:, contacts:)
    @query = query
    @finance = finance
    @contacts = contacts
    @columns = Array(columns).map(&:to_s).uniq.presence || DEFAULT_COLUMNS
    unknown = @columns - COLUMNS.keys
    raise OrganizerSalesQuery::InvalidFilter, "Invalid columns: #{unknown.join(', ')}" if unknown.any?
    raise OrganizerSalesQuery::InvalidFilter, "Financial columns require finance access" if !finance && (@columns & FINANCE_COLUMNS).any?
    raise OrganizerSalesQuery::InvalidFilter, "Contact columns require attendee or finance access" if !contacts && (@columns & CONTACT_COLUMNS).any?
    raise OrganizerSalesQuery::InvalidFilter, "Phone and notes require finance access" if !finance && (@columns & SENSITIVE_COLUMNS).any?
  end

  attr_reader :columns

  def header
    columns.map { |column| COLUMNS.fetch(column) }
  end

  def each_row
    return enum_for(:each_row) unless block_given?

    @query.each_batch do |record|
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
    when "price_paid" then money(ticket ? (item && item.unit_price_cents - item.discount_cents / item.quantity) : order.total_cents)
    when "fee" then money(ticket ? (item && item.fee_cents / item.quantity) : order.service_fee_cents)
    when "discount_promo" then [money(ticket ? (item && item.discount_cents / item.quantity) : order.discount_cents), order.promo_code&.code].compact.join(" / ")
    when "channel" then FinanceExports.channel(order)
    when "status" then ticket ? (order.refunded? || order.partially_refunded? ? order.status : ticket.status) : order.status
    when "check_in_time" then self.class.local_time(ticket ? ticket.checked_in_at : order.tickets.filter_map(&:checked_in_at).max, @query.event)
    when "transferred_to" then transferred_to(ticket ? [ticket] : order.tickets)
    when "purchase_date" then self.class.local_time(order.completed_at || order.created_at, @query.event)
    when "notes_custom_answers" then notes_and_answers(ticket, order)
    end
  end

  def money(cents)
    return nil unless cents

    SpreadsheetExport::Amount.new(format("%.2f", cents.to_f / 100))
  end

  def notes_and_answers(ticket, order)
    notes = [*order.support_notes, *(ticket ? ticket.support_notes : [])].map(&:body)
    answers = order.registration_responses.map { |answer| "#{answer.prompt_snapshot}: #{answer.answer.to_json}" }
    (notes + answers).join("; ")
  end

  def transferred_to(tickets)
    tickets.filter_map { |row| row.ticket_transfers.select(&:accepted?).max_by(&:id)&.recipient_email }.uniq.join("; ")
  end
end
