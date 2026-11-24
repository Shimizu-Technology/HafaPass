# frozen_string_literal: true

module Admissions
  # Aggregate in PostgreSQL: a scan ACK must not instantiate the event's ticket,
  # payment, refund or dispute graph. These are current persisted states, not
  # saleable stock or physical occupancy. `remaining` is the legacy issued alias.
  class Counts
    # Ruby String#blank?'s Unicode whitespace, independent of PostgreSQL locale.
    BLANK_CHARACTERS = "\u0009\u000a\u000b\u000c\u000d \u0085\u00a0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200a\u2028\u2029\u202f\u205f\u3000".freeze
    HEADCOUNT_CACHE_TTL = 12.seconds

    def self.call(event:)
      new(event).call
    end

    def self.headcount_cache_key(event, service_day)
      generation = Rails.cache.read("admissions:headcount_gen:v1:event:#{event.id}") || 0
      "admissions:headcount_by_day:v1:event:#{event.id}:g:#{generation}:day:#{service_day}:mode:#{event.re_entry_mode}"
    end

    def self.expire_headcount_cache!(event)
      return unless event

      Rails.cache.write("admissions:headcount_gen:v1:event:#{event.id}", SecureRandom.hex(6), expires_in: 1.hour)
    end

    def initialize(event)
      @event = event
    end

    def call
      # Off mode executes the exact same SQL and returns the exact same keys as main.
      unless @event.re_entry_enabled?
        row = ActiveRecord::Base.connection.select_one(sql(include_re_entry: false)).symbolize_keys.transform_values(&:to_i)
        return row.merge(remaining: row.fetch(:issued))
      end

      current_service_day = @event.occupancy_day_for(Time.current).iso8601
      row = ActiveRecord::Base.connection.select_one(
        sql(include_re_entry: true, service_day: current_service_day)
      ).symbolize_keys.transform_values(&:to_i)
      base = row.merge(remaining: row.fetch(:issued))

      by_day = cached_headcount_by_day(current_service_day)
      live_headcount = if multi_night_pass_breakdown?(by_day)
        resolve_pass_live_headcount(by_day, current_service_day: current_service_day, fallback: row.fetch(:currently_inside))
      else
        row.fetch(:currently_inside)
      end

      base.merge(
        live_headcount: live_headcount,
        headcount_by_day: by_day
      )
    end

    private

    def sql(include_re_entry:, service_day: nil)
      re_entry_columns = if include_re_entry
        quoted_day = ActiveRecord::Base.connection.quote(service_day)
        <<~SQL.chomp
          ,
          COUNT(*) FILTER (WHERE t.status = #{Ticket.statuses.fetch('checked_in')} AND t.occupancy_state = 'inside' AND t.occupancy_day = #{quoted_day}) AS currently_inside,
          COUNT(*) FILTER (WHERE t.status = #{Ticket.statuses.fetch('checked_in')} AND t.occupancy_day IS NULL) AS untracked_pre_re_entry_admits,
          COUNT(*) FILTER (WHERE t.re_entry_conflict_flagged = TRUE) AS conflict_tickets,
          (SELECT COUNT(*) FROM admission_actions a WHERE a.event_id = #{@event.id.to_i} AND a.kind = #{AdmissionAction.kinds.fetch('exit')} AND a.result = #{AdmissionAction.results.fetch('accepted')}) AS exits,
          (SELECT COUNT(*) FROM admission_actions a WHERE a.event_id = #{@event.id.to_i} AND a.kind = #{AdmissionAction.kinds.fetch('admit')} AND a.result = #{AdmissionAction.results.fetch('accepted')} AND a.reason_code = 're_entered') AS re_entries
        SQL
      else
        ""
      end

      <<~SQL
        WITH event_orders AS (
          SELECT DISTINCT order_id FROM tickets WHERE event_id = #{@event.id.to_i}
        ), refund_totals AS (
          SELECT r.order_id, SUM(r.amount_cents) AS reserved, BOOL_OR(r.status = #{Refund.statuses.fetch('pending')}) AS pending
          FROM refunds r JOIN orders o ON o.id = r.order_id
          WHERE o.id IN (SELECT order_id FROM event_orders)
            AND r.status IN (#{Refund.statuses.values_at('pending', 'succeeded').join(',')})
          GROUP BY r.order_id
        ), eligible_orders AS (
          SELECT o.id FROM orders o LEFT JOIN refund_totals rf ON rf.order_id = o.id
          WHERE o.id IN (SELECT order_id FROM event_orders)
            AND o.status IN (#{Order.statuses.values_at('completed', 'partially_refunded').join(',')})
            AND NOT (o.total_cents > 0 AND COALESCE(rf.pending, FALSE) AND rf.reserved >= o.total_cents)
            AND NOT EXISTS (SELECT 1 FROM disputes d WHERE d.order_id = o.id AND d.status IN (#{Dispute.statuses.values_at('open', 'lost').join(',')}))
            AND #{payment_predicate}
        )
        SELECT COUNT(*) AS total,
          COUNT(*) FILTER (WHERE t.status = #{Ticket.statuses.fetch('issued')}) AS issued,
          COUNT(*) FILTER (WHERE t.status = #{Ticket.statuses.fetch('checked_in')}) AS admitted,
          COUNT(*) FILTER (WHERE t.status = #{Ticket.statuses.fetch('cancelled')}) AS cancelled,
          COUNT(*) FILTER (WHERE t.status = #{Ticket.statuses.fetch('issued')} AND eo.id IS NOT NULL
            AND #{@event.published? ? 'TRUE' : 'FALSE'}
            AND NOT EXISTS (SELECT 1 FROM ticket_inventory_retentions ir
              WHERE ir.ticket_id = t.id OR (t.parent_ticket_id IS NOT NULL AND ir.ticket_id = t.parent_ticket_id))
            AND NOT EXISTS (SELECT 1 FROM refund_tickets rt JOIN refunds r ON r.id = rt.refund_id
              WHERE (rt.ticket_id = t.id OR (t.parent_ticket_id IS NOT NULL AND rt.ticket_id = t.parent_ticket_id))
                AND rt.released_at IS NULL AND r.status = #{Refund.statuses.fetch('pending')})) AS eligible_unadmitted,
          (SELECT COUNT(*) FROM admission_actions a WHERE a.event_id = #{@event.id.to_i} AND a.result = #{AdmissionAction.results.fetch('conflict')}) AS conflicts,
          (SELECT COUNT(*) FROM admission_actions a WHERE a.event_id = #{@event.id.to_i} AND a.result = #{AdmissionAction.results.fetch('rejected')}) AS rejected#{re_entry_columns}
        FROM tickets t
        JOIN ticket_types tt ON tt.id = t.ticket_type_id
        LEFT JOIN eligible_orders eo ON eo.id = t.order_id
        WHERE t.event_id = #{@event.id.to_i}
          AND NOT (t.parent_ticket_id IS NULL AND tt.is_pass)
          AND (t.parent_ticket_id IS NULL OR NOT EXISTS (
            SELECT 1 FROM tickets parent_t
            WHERE parent_t.id = t.parent_ticket_id
              AND parent_t.status = #{Ticket.statuses.fetch('cancelled')}
          ))
      SQL
    end

    def payment_predicate
      return "TRUE" unless Rails.env.production?

      environments = SiteSetting.instance.payment_mode == "test" ? "'live','test'" : "'live'"
      <<~SQL.squish
        (o.total_cents <= 0 OR EXISTS (
          SELECT 1 FROM payments p WHERE p.order_id = o.id
            AND p.status IN (#{Payment.statuses.values_at('succeeded', 'partially_refunded').join(',')})
            AND p.amount_cents >= o.total_cents AND p.currency = o.currency
            AND #{present_sql('p.provider_payment_id')} AND LEFT(p.provider_payment_id, 4) <> 'sim_'
            AND (p.provider_payload -> 'simulated') IS DISTINCT FROM 'true'::jsonb
            AND (p.provider <> 'stripe' OR (p.provider_environment IN (#{environments}) AND #{present_sql('p.provider_platform_account_id')}))
        ))
      SQL
    end

    def present_sql(column)
      # Keep whitespace out of the literal while payment_predicate is squished.
      characters = BLANK_CHARACTERS.codepoints.map { |point| "\\#{point.to_s(16).rjust(4, '0')}" }.join
      "LENGTH(translate(#{column}, U&'#{characters}', '')) > 0"
    end

    def multi_night_pass_breakdown?(by_day)
      by_day.any? { |entry| entry[:event_id].present? && entry[:event_id] != @event.id }
    end

    def resolve_pass_live_headcount(by_day, current_service_day:, fallback:)
      return fallback if by_day.empty?

      today_entry = by_day.find { |entry| entry[:day] == current_service_day }
      return today_entry[:headcount] if today_entry
      return 0 if by_day.last[:day] < current_service_day

      by_day.last[:headcount]
    end

    def cached_headcount_by_day(current_service_day)
      Rails.cache.fetch(self.class.headcount_cache_key(@event, current_service_day), expires_in: HEADCOUNT_CACHE_TTL) do
        headcount_by_day
      end
    end

    def headcount_by_day
      report = ReEntryReport.call(event: @event)
      report.fetch(:by_day).map do |entry|
        {
          day: entry[:day],
          label: entry[:label],
          event_id: entry[:event_id],
          event_title: entry[:event_title],
          entries: entry[:entries],
          exits: entry[:exits],
          re_entries: entry[:re_entries],
          headcount: entry[:current_headcount],
          peak_headcount: entry[:peak_headcount],
          peak_headcount_at: entry[:peak_headcount_at]
        }.compact
      end
    end
  end
end
