# frozen_string_literal: true

# Read-only sales and traffic breakdowns for one event's analytics page.
# Days are calendar days in the event's own timezone.
class EventSalesAnalytics
  SETTLED_ORDER_STATUSES = %i[completed partially_refunded refunded].freeze
  CHANNELS = %w[online box_office guest_list].freeze
  # Funnel views come from an anonymous, best-effort browser ping, so a rate
  # from a handful of visitors would be noise rather than a conversion figure.
  MIN_VISITORS_FOR_CONVERSION = 25
  MAX_FILLED_DAYS = 731

  def self.call(event)
    new(event).call
  end

  def initialize(event)
    @event = event
  end

  def call
    {
      timezone: timezone.tzinfo.name,
      sales_by_day: sales_by_day,
      sales_by_channel: sales_by_channel,
      traffic: traffic
    }
  end

  private

  attr_reader :event

  def timezone
    @timezone ||= ActiveSupport::TimeZone[event.timezone.to_s] || Time.zone
  end

  def orders
    @orders ||= event.orders.where(status: SETTLED_ORDER_STATUSES)
  end

  def order_rows
    @order_rows ||= orders.pluck(:id, :completed_at, :created_at, :total_cents, :source)
  end

  def tickets_by_order
    @tickets_by_order ||= event.tickets.where(order_id: orders.select(:id)).where.not(status: :cancelled)
      .group(:order_id).count
  end

  def purchased_tickets_by_order
    @purchased_tickets_by_order ||= OrderItem.where(order_id: orders.select(:id), item_kind: :ticket)
      .group(:order_id).sum(:quantity)
  end

  def refunds_by_order
    @refunds_by_order ||= Refund.succeeded.where(order_id: orders.select(:id)).group(:order_id).sum(:amount_cents)
  end

  # Tickets bought and the amount charged, by the day each order was placed.
  # Both are as purchased: later refunds and cancellations do not move back
  # onto the day of the original sale (the channel totals are after them).
  def sales_by_day
    days = Hash.new { |hash, key| hash[key] = { orders: 0, tickets: 0, amount_cents: 0 } }
    order_rows.each do |id, completed_at, created_at, total_cents, _source|
      day = (completed_at || created_at).in_time_zone(timezone).to_date
      days[day][:orders] += 1
      days[day][:tickets] += purchased_tickets_by_order.fetch(id, 0)
      days[day][:amount_cents] += total_cents
    end
    return [] if days.empty?

    first, last = days.keys.minmax
    range = (last - first).to_i < MAX_FILLED_DAYS ? (first..last).to_a : days.keys.sort
    range.map { |day| { date: day.iso8601 }.merge(days.fetch(day, { orders: 0, tickets: 0, amount_cents: 0 })) }
  end

  # Amount is net of succeeded refunds, matching the page's revenue total.
  def sales_by_channel
    totals = CHANNELS.index_with { { orders: 0, tickets: 0, amount_cents: 0 } }
    order_rows.each do |id, _completed_at, _created_at, total_cents, source|
      channel = CHANNELS.include?(source) ? source : "online"
      totals[channel][:orders] += 1
      totals[channel][:tickets] += tickets_by_order.fetch(id, 0)
      totals[channel][:amount_cents] += total_cents - refunds_by_order.fetch(id, 0)
    end
    totals.map { |channel, values| { channel: channel }.merge(values) }
  end

  def traffic
    funnel = event.marketplace_funnel_events
    visitors = funnel.where(stage: %i[landing event_view]).distinct.count(:visitor_hash)
    purchasers = funnel.where(stage: :purchase).distinct.count(:visitor_hash)
    {
      visitors: visitors,
      checkout_visitors: funnel.where(stage: :checkout_started).distinct.count(:visitor_hash),
      purchasers: purchasers,
      sources: traffic_sources(funnel),
      conversion: conversion(visitors, purchasers)
    }
  end

  def traffic_sources(funnel)
    views = normalized(funnel.where(stage: %i[landing event_view]).group(:source, :medium).distinct.count(:visitor_hash))
    attributed = event.orders.where(status: SETTLED_ORDER_STATUSES).joins(:acquisition_attribution)
      .group("acquisition_attributions.source", "acquisition_attributions.medium")
    order_counts = normalized(attributed.count)
    order_amounts = normalized(attributed.sum(:total_cents))
    rows = (views.keys | order_counts.keys).map do |source, medium|
      key = [source, medium]
      { source: source, medium: medium, visitors: views[key], orders: order_counts[key], amount_cents: order_amounts[key] }
    end
    rows.sort_by { |row| [-row[:visitors], -row[:orders], row[:source], row[:medium]] }
  end

  # Unlabelled traffic is reported the way order attribution records it.
  def normalized(grouped)
    grouped.each_with_object(Hash.new(0)) do |((source, medium), value), totals|
      totals[[source.presence || "direct", medium.presence || "none"]] += value
    end
  end

  def conversion(visitors, purchasers)
    sufficient = visitors >= MIN_VISITORS_FOR_CONVERSION
    {
      estimate: true,
      sufficient_data: sufficient,
      minimum_visitors: MIN_VISITORS_FOR_CONVERSION,
      rate: sufficient ? (purchasers.to_f / visitors).clamp(0, 1).round(4) : nil
    }
  end
end
