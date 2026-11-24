# frozen_string_literal: true

class EventReportingService
  STATUSES = %w[paid completed partially_refunded refunded cancelled pending expired issued checked_in not_checked_in transferred].freeze
  ACTIVE_ORDER_STATUSES = %w[completed partially_refunded].freeze
  SETTLED_ORDER_STATUSES = (ACTIVE_ORDER_STATUSES + %w[refunded]).freeze

  def self.percentage(count, total)
    total.positive? ? (100.0 * count / total).round(1) : 0.0
  end

  def self.active_tickets(event, tickets = event.tickets.joins(:order))
    orders = Order.where(event_id: event.organization.events.select(:id))
      .excluding_test_payments.where(status: ACTIVE_ORDER_STATUSES)
      .where.not(id: Dispute.where(status: [:open, :lost]).select(:order_id))
    invalid_tickets = RefundTicket.active.joins(:refund).where(refunds: { status: [:pending, :succeeded] }).select(:ticket_id)
    invalid_parents = Ticket.where(status: [:cancelled, :transferred])
      .or(Ticket.where(id: invalid_tickets))
      .or(Ticket.where(id: TicketInventoryRetention.select(:ticket_id)))
      .select(:id)

    tickets.where(order_id: orders.select(:id), status: [:issued, :checked_in])
      .where.not(id: invalid_tickets).where.not(id: TicketInventoryRetention.select(:ticket_id))
      .where("tickets.parent_ticket_id IS NULL OR tickets.parent_ticket_id NOT IN (?)", invalid_parents)
  end

  def self.filter_status(tickets, status)
    case status
    when nil then tickets
    when "paid" then tickets.where(orders: { status: ACTIVE_ORDER_STATUSES })
    when "cancelled" then tickets.where("tickets.status = ? OR orders.status = ?", Ticket.statuses[:cancelled], Order.statuses[:cancelled])
    when *Order.statuses.keys then tickets.where(orders: { status: status })
    when "not_checked_in" then tickets.where(status: :issued)
    else tickets.where(status: status)
    end
  end

  def self.filter_channel(orders, channel)
    case channel
    when nil then orders
    when "online" then orders.where("orders.source IS NULL OR orders.source NOT IN (?)", %w[box_office guest_list])
    else orders.where(source: channel)
    end
  end

  attr_reader :zone

  def initialize(event:, params: {})
    @event = event
    @status = params[:status].presence
    @channel = params[:channel].presence
    @type_id = params[:ticket_type_id].presence
    @zone = ActiveSupport::TimeZone[event.timezone.presence || "Pacific/Guam"] || ActiveSupport::TimeZone["Pacific/Guam"]
    validate!
  end

  def sales
    sales = EventReportSales.new(event: @event, orders: sales_orders, ticket_type_id: @type_id&.to_i, status: @status)
    rows, financials, order_count, tickets_issued = sales.call
    { summary: financials.merge(unique_orders: order_count, tickets_issued: tickets_issued), sales_by_tier: rows }
  end

  def attendance
    tickets = eligible_tickets.scannable
    # Derive both the rate and the pace from the same read while doors are busy.
    groups = tickets.group(:ticket_type_id, :status, :checked_in_at).count
    by_type = groups.group_by { |(id, _status, _time), _count| id }
    names = TicketType.where(id: by_type.keys).pluck(:id, :name).to_h
    counts = by_type.map do |id, rows|
      checked = rows.sum { |(_type, status, _time), count| status == "checked_in" ? count : 0 }
      attendance_counts(rows.sum(&:last), checked).merge(ticket_type_id: id, ticket_type_name: names[id])
    end
    filtered_ids = (@type_id || @channel || @status) ? tickets.select(:id) : nil
    attendance_counts(counts.sum { |type| type[:total_active_tickets] }, counts.sum { |type| type[:checked_in_count] }).merge(
      by_ticket_type: counts.sort_by { |type| [type[:ticket_type_name].to_s.downcase, type[:ticket_type_id]] },
      timezone: zone.tzinfo.identifier, pace: pace(groups),
      re_entry: Admissions::ReEntryReport.call(event: event, ticket_ids: filtered_ids, zone: zone)
    )
  end

  def registrations
    @registrations ||= EventReportRegistrations.new(event: @event, tickets: eligible_tickets)
  end

  private

  attr_reader :event

  def validate!
    invalid = OrganizerSalesQuery::InvalidFilter
    raise invalid, "Invalid status" if @status && !STATUSES.include?(@status)
    raise invalid, "Invalid channel" if @channel && !OrganizerSalesQuery::CHANNELS.include?(@channel)
    return unless @type_id

    unless @type_id.to_s.match?(/\A[1-9][0-9]*\z/) && event.ticket_types.exists?(@type_id)
      raise invalid, "Invalid ticket type"
    end
  end

  def sales_orders
    orders = self.class.filter_channel(event.orders.excluding_test_payments, @channel)
    orders.where(status: SETTLED_ORDER_STATUSES)
  end

  def eligible_tickets
    @eligible_tickets ||= begin
      tickets = self.class.active_tickets(event)
      tickets = tickets.merge(self.class.filter_channel(Order.all, @channel))
      tickets = tickets.where(ticket_type_id: @type_id) if @type_id
      self.class.filter_status(tickets, @status)
    end
  end

  def attendance_counts(total, checked)
    {
      total_active_tickets: total, checked_in_count: checked, remaining_count: total - checked,
      check_in_rate: self.class.percentage(checked, total)
    }
  end

  def pace(groups)
    buckets = Hash.new(0)
    groups.each do |(_type, status, timestamp), count|
      next unless status == "checked_in" && timestamp

      local = timestamp.in_time_zone(zone)
      # Subtract elapsed seconds to preserve the offset in a repeated DST hour.
      bucket = local.at_beginning_of_minute - (local.min % 30).minutes
      buckets[bucket] += count
    end
    buckets.sort_by(&:first).map do |start, count|
      { bucket_start: start.iso8601, label: start.strftime("%-I:%M %p"), count: count }
    end
  end
end
