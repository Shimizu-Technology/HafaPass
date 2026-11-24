# frozen_string_literal: true

module Operations
  # Read-only Guam-day sales and health summary for the morning brief
  # (GET /api/v1/ops/summary, scripts/fetch_ops_summary.py). Aggregates only:
  # counts, money and event titles. No buyer, attendee or staff names, emails,
  # phone numbers, order references, payment ids or tokens appear anywhere.
  #
  # Sales are the orders that completed in the Guam day, so a late-night door
  # sale lands on the day it happened; refunds are the refunds that succeeded
  # in that day (they can belong to earlier orders). Outside production every
  # payment counts; in production Order.excluding_test_payments drops test and
  # simulated Stripe orders, the same rule as the admin dashboard.
  class DailySummary
    ZONE = "Pacific/Guam"
    MAX_EVENTS = 50
    SETTLED = %i[completed partially_refunded refunded].freeze

    def self.call(date: nil, now: Time.current)
      new(date: date, now: now).call
    end

    def self.zone = ActiveSupport::TimeZone[ZONE]

    # nil → yesterday in Guam (the previous full day, which is what a morning
    # brief wants); "today" → the day so far.
    def self.resolve_date(value, now: Time.current)
      today = now.in_time_zone(zone).to_date
      return today - 1 if value.blank?
      return today if value.to_s == "today"

      date = Date.iso8601(value.to_s)
      raise ArgumentError, "date must not be in the future" if date > today

      date
    rescue Date::Error
      raise ArgumentError, "date must be YYYY-MM-DD, or today"
    end

    def initialize(date: nil, now: Time.current)
      @now = now
      @date = self.class.resolve_date(date, now: now)
      zone = self.class.zone
      @window = zone.local(@date.year, @date.month, @date.day)...zone.local(@date.year, @date.month, @date.day).next_day
    end

    def call
      # The whole read, readiness included, runs with database writes blocked.
      # SystemReadiness(read_only: true) skips the one check that can write
      # (it activates due fee changes), so this GET never changes data.
      ActiveRecord::Base.while_preventing_writes do
        readiness = SystemReadiness.call(read_only: true)
        {
          guam_date: date.iso8601,
          window: { starts_at: window.begin.iso8601, ends_at: window.end.iso8601, partial: window.end > now },
          generated_at: now.iso8601,
          revision: ApplicationRevision.configured? ? ApplicationRevision.current.downcase : nil,
          environment: Rails.env,
          sales: sales,
          events: events,
          on_sale: on_sale,
          health: health(readiness)
        }
      end
    end

    private

    attr_reader :now, :date, :window

    def orders
      @orders ||= Order.excluding_test_payments.where(status: SETTLED, completed_at: window)
    end

    def cash_order_ids
      @cash_order_ids ||= orders.where(payment_method: "door_cash")
        .or(orders.where(id: Payment.where(provider: "door_cash").select(:order_id))).pluck(:id)
    end

    def refunds
      @refunds ||= Refund.succeeded.where(succeeded_at: window, order_id: Order.excluding_test_payments.select(:id))
    end

    def order_ids = @order_ids ||= orders.pluck(:id)

    def sales
      @sales ||= begin
        cash = orders.where(id: cash_order_ids)
        online = orders.where.not(id: cash_order_ids)
        {
          orders: orders.count,
          tickets: tickets_by_order_scope(orders).sum { |_event_id, count| count },
          gross_cents: orders.sum(:total_cents),
          refund_cents: refunds.sum(:amount_cents),
          refund_count: refunds.count,
          fees_cents: fee_totals,
          door_cash: { orders: cash.count, gross_cents: cash.sum(:total_cents) },
          online: { orders: online.count, gross_cents: online.sum(:total_cents) }
        }
      end
    end

    def fee_totals
      totals = FeeComponent.where(order_id: order_ids).group(:kind).sum(:amount_cents)
      FeeComponent::KINDS.index_with { |kind| totals.fetch(kind, 0) }
    end

    # Tickets that stayed valid (not cancelled) for these orders, by event.
    def tickets_by_order_scope(scope)
      Ticket.where(order_id: scope.select(:id)).where.not(status: Ticket.statuses[:cancelled]).group(:event_id).count
    end

    def events
      per_event = orders.group(:event_id)
      order_counts = per_event.count
      gross = per_event.sum(:total_cents)
      cash_gross = orders.where(id: cash_order_ids).group(:event_id).sum(:total_cents)
      tickets = tickets_by_order_scope(orders)
      refund_cents = refunds.joins(:order).group("orders.event_id").sum(:amount_cents)
      fees = FeeComponent.where(order_id: order_ids).joins(:order).group("orders.event_id").sum(:amount_cents)

      ids = (order_counts.keys | refund_cents.keys).first(MAX_EVENTS)
      titles = Event.where(id: ids).pluck(:id, :title).to_h
      ids.map do |id|
        { event_id: id, title: titles[id].to_s.truncate(120), orders: order_counts.fetch(id, 0), tickets: tickets.fetch(id, 0),
          gross_cents: gross.fetch(id, 0), refund_cents: refund_cents.fetch(id, 0), fees_cents: fees.fetch(id, 0),
          door_cash_gross_cents: cash_gross.fetch(id, 0), online_gross_cents: gross.fetch(id, 0) - cash_gross.fetch(id, 0) }
      end.sort_by { |row| [-row[:gross_cents], row[:event_id]] }
    end

    # Capacity left right now on events that are selling, so the brief can say
    # "Copa has 212 of 900 left". Always current, whatever date was asked for.
    def on_sale
      Event.published.where("events.ends_at IS NULL OR events.ends_at > ?", now).includes(:ticket_types)
        .order(:starts_at).limit(MAX_EVENTS).select { |event| event.sales_open?(at: now) }.map do |event|
          remaining = event.remaining_capacity(at: now)
          { event_id: event.id, title: event.title.to_s.truncate(120), starts_at: event.starts_at&.iso8601,
            max_capacity: event.max_capacity, capacity_remaining: remaining.finite? ? remaining : nil,
            ticket_types: event.ticket_types.sort_by { |type| [type.sort_order.to_i, type.id] }.map do |type|
              { name: type.name.to_s.truncate(80), on_sale: type.on_sale?(at: now), remaining: type.available_quantity }
            end }
        end
    end

    def health(readiness)
      checks = readiness.fetch(:checks)
      {
        readiness: readiness.fetch(:status),
        skipped_checks: readiness.dig(:checks, :provider_policy_controls, :status) == "not_checked" ? %w[provider_policy_controls] : [],
        checks: { database: checks.dig(:database, :ready), job_queue: checks.dig(:job_queue, :ready), worker: checks.dig(:worker, :ready),
                  commerce_clock: checks.dig(:commerce_clock, :ready), configuration: checks.dig(:configuration, :ready) },
        stripe_webhooks: Operations::StripeWebhookHealth.call(now: now),
        operational_signals: OperationalAlertJob.signals(now: now),
        job_queue: job_queue,
        error_counts: { source: "operational_signals", sentry: "not_available_here",
          note: "Unhandled exceptions and error spikes are in Sentry; open the Sentry app for those." }
      }
    end

    def job_queue
      return { available: false } unless SolidQueue::Job.table_exists?

      oldest = SolidQueue::ReadyExecution.minimum(:created_at)
      { available: true, ready: SolidQueue::ReadyExecution.count, claimed: SolidQueue::ClaimedExecution.count,
        failed: SolidQueue::FailedExecution.count, oldest_ready_age_seconds: oldest ? (now - oldest).to_i : 0 }
    end
  end
end
