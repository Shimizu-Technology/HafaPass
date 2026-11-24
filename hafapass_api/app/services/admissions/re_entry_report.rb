# frozen_string_literal: true

module Admissions
  # Computes re-entry & headcount metrics (entries, exits, re-entries, overrides,
  # current headcount, peak headcount + timestamp) overall and per service day
  # directly in PostgreSQL via window functions (no Ruby per-action replay).
  # Supports single-day events, multi-day single events, and multi-night pass events.
  class ReEntryReport
    def self.call(event:, ticket_ids: nil, zone: nil)
      new(event: event, ticket_ids: ticket_ids, zone: zone).call
    end

    def initialize(event:, ticket_ids: nil, zone: nil)
      @event = event
      @ticket_ids = ticket_ids
      @zone = zone || event.event_time_zone
    end

    def call
      pass_nights = included_pass_events
      if pass_nights.any? && @ticket_ids.nil?
        call_multi_night_pass(pass_nights)
      else
        call_single_event(@event, @ticket_ids)
      end
    end

    private

    def included_pass_events
      Event.joins("INNER JOIN ticket_type_included_events ttie ON ttie.included_event_id = events.id")
        .joins("INNER JOIN ticket_types tt ON tt.id = ttie.ticket_type_id")
        .where(tt: { event_id: @event.id, is_pass: true })
        .distinct.order(:starts_at, :id).to_a
    end

    def call_single_event(target_event, ticket_ids)
      by_day = sql_days(target_event, ticket_ids: ticket_ids, event_title: nil, zone: @zone)
      overall = aggregate_overall(by_day)
      overall.merge(by_day: by_day).merge(policy_metadata)
    end

    def call_multi_night_pass(pass_nights)
      pass_parent_ids = @event.tickets.joins(:ticket_type).where(parent_ticket_id: nil, ticket_types: { is_pass: true }).pluck(:id)
      by_day = pass_nights.flat_map do |night|
        night_zone = night.event_time_zone
        night_ticket_ids = pass_parent_ids.empty? ? [] : Ticket.where(event_id: night.id, parent_ticket_id: pass_parent_ids).pluck(:id)
        days = night_ticket_ids.empty? ? [] : sql_days(night, ticket_ids: night_ticket_ids, event_title: night.title, zone: night_zone)
        if days.empty? && night.starts_at
          night_day = night.occupancy_day_for(night.starts_at)
          days = [empty_day_row(night_day, event_id: night.id, event_title: night.title)]
        end
        days
      end

      overall = aggregate_overall(by_day)
      overall.merge(by_day: by_day).merge(policy_metadata)
    end

    BASE_SQL = <<~SQL
      WITH relevant_actions AS (
        SELECT
          a.id,
          a.ticket_id,
          a.kind,
          a.result,
          a.reason_code,
          a.occurred_at,
          a.received_at,
          COALESCE(
            a.occupancy_day,
            (((a.occurred_at AT TIME ZONE 'UTC') AT TIME ZONE :tz_name) - (:rollover_hours * INTERVAL '1 hour'))::date
          ) AS day,
          CASE
            WHEN a.result = :accepted AND a.kind = :admit AND NOT EXISTS (
              SELECT 1 FROM admission_actions rev
              WHERE rev.reverses_action_id = a.id
                AND rev.kind = :reverse
                AND rev.result = :accepted
            ) THEN 'inside'
            WHEN a.result = :accepted AND a.kind = :exit_kind THEN 'outside'
            WHEN a.result = :accepted AND a.kind = :override AND a.reason_code = 'lead_override_admitted' THEN 'inside'
            WHEN a.result = :accepted AND a.kind = :override AND a.reason_code = 'lead_override_cleared' THEN 'outside'
            ELSE NULL
          END AS target_state
        FROM admission_actions a
        WHERE a.event_id = :event_id
          %<ticket_clause>s
      ),
      state_steps AS (
        SELECT
          day,
          occurred_at,
          received_at,
          id,
          CASE
            WHEN ticket_id IS NULL THEN 0
            WHEN target_state = 'inside' AND COALESCE(
              LAG(target_state) OVER (
                PARTITION BY day, ticket_id
                ORDER BY occurred_at ASC, received_at ASC, id ASC
              ), 'outside'
            ) <> 'inside' THEN 1
            WHEN target_state = 'outside' AND COALESCE(
              LAG(target_state) OVER (
                PARTITION BY day, ticket_id
                ORDER BY occurred_at ASC, received_at ASC, id ASC
              ), 'outside'
            ) = 'inside' THEN -1
            ELSE 0
          END AS delta
        FROM relevant_actions
        WHERE target_state IS NOT NULL
      ),
      running AS (
        SELECT
          day,
          occurred_at,
          received_at,
          id,
          SUM(delta) OVER (
            PARTITION BY day
            ORDER BY occurred_at ASC, received_at ASC, id ASC
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
          ) AS running_inside
        FROM state_steps
      ),
      peaks AS (
        SELECT DISTINCT ON (day)
          day,
          GREATEST(running_inside, 0) AS peak_headcount,
          CASE WHEN running_inside > 0 THEN occurred_at ELSE NULL END AS peak_headcount_at
        FROM running
        ORDER BY day, running_inside DESC, occurred_at ASC, received_at ASC, id ASC
      ),
      day_totals AS (
        SELECT
          day,
          COUNT(*) FILTER (WHERE result = :accepted AND kind = :admit AND target_state = 'inside' AND reason_code <> 're_entered') AS entries,
          COUNT(*) FILTER (WHERE result = :accepted AND kind = :exit_kind) AS exits,
          COUNT(*) FILTER (WHERE result = :accepted AND kind = :admit AND target_state = 'inside' AND reason_code = 're_entered') AS re_entries,
          COUNT(*) FILTER (WHERE result = :accepted AND kind = :override) AS overrides,
          COUNT(*) FILTER (WHERE result = :conflict) AS conflicts_count
        FROM relevant_actions
        GROUP BY day
      ),
      final_inside AS (
        SELECT day, GREATEST(SUM(delta), 0) AS current_headcount
        FROM state_steps
        GROUP BY day
      )
      SELECT
        t.day,
        t.entries,
        t.exits,
        t.re_entries,
        t.overrides,
        t.conflicts_count,
        COALESCE(f.current_headcount, 0) AS current_headcount,
        COALESCE(p.peak_headcount, 0) AS peak_headcount,
        p.peak_headcount_at
      FROM day_totals t
      LEFT JOIN final_inside f ON f.day = t.day
      LEFT JOIN peaks p ON p.day = t.day
      ORDER BY t.day ASC
    SQL
    SQL_ALL_TICKETS = format(BASE_SQL, ticket_clause: "").freeze
    SQL_FILTERED_TICKETS = format(BASE_SQL, ticket_clause: "AND a.ticket_id IN (:ticket_ids)").freeze

    def sql_days(target_event, ticket_ids:, event_title:, zone:)
      conn = ActiveRecord::Base.connection
      binds = {
        tz_name: zone.tzinfo.name,
        rollover_hours: target_event.re_entry_rollover_hour.to_i,
        event_id: target_event.id.to_i,
        admit: AdmissionAction.kinds.fetch("admit"),
        reverse: AdmissionAction.kinds.fetch("reverse"),
        exit_kind: AdmissionAction.kinds.fetch("exit"),
        override: AdmissionAction.kinds.fetch("override"),
        accepted: AdmissionAction.results.fetch("accepted"),
        conflict: AdmissionAction.results.fetch("conflict")
      }

      template = if ticket_ids.nil?
        SQL_ALL_TICKETS
      else
        ids = if ticket_ids.is_a?(ActiveRecord::Relation)
          ticket_ids.pluck(:id)
        else
          Array(ticket_ids).map { |v| v.respond_to?(:id) ? v.id : v.to_i }
        end.uniq
        return [] if ids.empty?

        binds[:ticket_ids] = ids
        SQL_FILTERED_TICKETS
      end

      sanitized = ActiveRecord::Base.sanitize_sql_array([template, binds])
      conn.select_all(sanitized).map do |row|
        day = row["day"].is_a?(Date) ? row["day"] : Date.iso8601(row["day"].to_s)
        peak_raw = row["peak_headcount_at"]
        peak_time = if peak_raw.is_a?(Time) || peak_raw.is_a?(ActiveSupport::TimeWithZone)
          peak_raw.in_time_zone(zone)
        elsif peak_raw.present?
          ActiveSupport::TimeZone["UTC"].parse(peak_raw.to_s)&.in_time_zone(zone)
        end
        {
          day: day.iso8601,
          label: day.strftime("%b %-d, %Y"),
          event_id: target_event.id,
          event_title: event_title,
          entries: row["entries"].to_i,
          exits: row["exits"].to_i,
          re_entries: row["re_entries"].to_i,
          overrides: row["overrides"].to_i,
          conflicts_count: row["conflicts_count"].to_i,
          current_headcount: row["current_headcount"].to_i,
          peak_headcount: row["peak_headcount"].to_i,
          peak_headcount_at: peak_time&.iso8601,
          peak_headcount_label: peak_time&.strftime("%-I:%M %p")
        }.compact
      end
    end

    def aggregate_overall(by_day)
      current_day = @event.occupancy_day_for(Time.current).iso8601
      today_row = by_day.find { |d| d[:day] == current_day }
      current_headcount = if today_row
        today_row[:current_headcount]
      elsif by_day.any? && by_day.last[:day] < current_day
        0
      else
        by_day.last&.fetch(:current_headcount, 0) || 0
      end
      peak_row = by_day.max_by { |d| [d[:peak_headcount].to_i, -(Date.iso8601(d[:day]).jd)] }
      {
        entries: by_day.sum { |d| d[:entries].to_i },
        exits: by_day.sum { |d| d[:exits].to_i },
        re_entries: by_day.sum { |d| d[:re_entries].to_i },
        overrides: by_day.sum { |d| d[:overrides].to_i },
        conflicts_count: by_day.sum { |d| d[:conflicts_count].to_i },
        current_headcount: current_headcount,
        peak_headcount: peak_row&.dig(:peak_headcount).to_i,
        peak_headcount_at: peak_row&.dig(:peak_headcount_at),
        peak_headcount_label: peak_row&.dig(:peak_headcount_label)
      }
    end

    def empty_day_row(day, event_id:, event_title:)
      {
        day: day.iso8601,
        label: day.strftime("%b %-d, %Y"),
        event_id: event_id,
        event_title: event_title,
        entries: 0,
        exits: 0,
        re_entries: 0,
        overrides: 0,
        conflicts_count: 0,
        current_headcount: 0,
        peak_headcount: 0,
        peak_headcount_at: nil,
        peak_headcount_label: nil
      }.compact
    end

    def policy_metadata
      {
        mode: @event.re_entry_mode,
        max_count: @event.re_entry_max_count,
        cutoff_at: @event.re_entry_cutoff_at&.in_time_zone(@zone)&.iso8601,
        cutoff_time: @event.re_entry_cutoff_time,
        cooldown_minutes: @event.re_entry_cooldown_minutes,
        rollover_hour: @event.re_entry_rollover_hour
      }
    end
  end
end
