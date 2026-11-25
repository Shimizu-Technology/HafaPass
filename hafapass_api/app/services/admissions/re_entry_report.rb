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
      now = Time.current
      pass_nights = included_pass_events
      if pass_nights.any? && @ticket_ids.nil?
        call_multi_night_pass(pass_nights, now: now)
      else
        call_single_event(@event, @ticket_ids, now: now)
      end
    end

    private

    def included_pass_events
      Event.joins("INNER JOIN ticket_type_included_events ttie ON ttie.included_event_id = events.id")
        .joins("INNER JOIN ticket_types tt ON tt.id = ttie.ticket_type_id")
        .where(tt: { event_id: @event.id, is_pass: true })
        .distinct.order(:starts_at, :id).to_a
    end

    def call_single_event(target_event, ticket_ids, now:)
      by_day = sql_days(target_event, ticket_ids: ticket_ids, event_title: nil, zone: @zone, now: now)
      overall = aggregate_overall(by_day, now: now)
      overall.merge(by_day: by_day).merge(policy_metadata(now: now))
    end

    def call_multi_night_pass(pass_nights, now:)
      rows_by_event, combined_peak = sql_multi_event(pass_nights, now: now)

      direct_days = rows_by_event.fetch(@event.id, [])
      by_day = direct_days + pass_nights.flat_map do |night|
        days = rows_by_event.fetch(night.id, [])
        if days.empty? && night.starts_at
          night_day = night.occupancy_day_for(night.starts_at)
          days = [empty_day_row(night_day, event: night, event_title: night.title, now: now)]
        end
        days
      end

      overall = aggregate_overall(by_day, combined_peak: combined_peak, now: now)
      overall.merge(by_day: by_day).merge(policy_metadata(now: now))
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
              WHERE rev.event_id = :event_id
                AND rev.reverses_action_id = a.id
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

    MULTI_EVENT_SQL_TEMPLATE = <<~SQL
      WITH event_specs (event_id, is_direct, tz_name, rollover_hours, session_day, session_end_at) AS (
        VALUES %<event_specs_values>s
      ),
      pass_child_tickets AS (
        SELECT child.id
        FROM tickets child
        INNER JOIN tickets parent ON parent.id = child.parent_ticket_id
        INNER JOIN ticket_types tt ON tt.id = parent.ticket_type_id
        WHERE parent.event_id = :parent_event_id
          AND parent.parent_ticket_id IS NULL
          AND tt.is_pass = TRUE
          AND child.event_id IN (:night_event_ids)
      ),
      scoped_actions AS (
        SELECT
          a.id,
          a.event_id,
          a.ticket_id,
          a.kind,
          a.result,
          a.reason_code,
          a.occurred_at,
          a.received_at,
          a.occupancy_day,
          es.tz_name,
          es.rollover_hours
        FROM admission_actions a
        INNER JOIN event_specs es ON es.event_id = a.event_id AND es.is_direct = TRUE
        WHERE a.event_id = :parent_event_id
        UNION ALL
        SELECT
          a.id,
          a.event_id,
          a.ticket_id,
          a.kind,
          a.result,
          a.reason_code,
          a.occurred_at,
          a.received_at,
          a.occupancy_day,
          es.tz_name,
          es.rollover_hours
        FROM admission_actions a
        INNER JOIN pass_child_tickets pct ON pct.id = a.ticket_id
        INNER JOIN event_specs es ON es.event_id = a.event_id AND es.is_direct = FALSE
        WHERE a.event_id IN (:night_event_ids)
      ),
      relevant_actions AS (
        SELECT
          a.id,
          a.event_id,
          a.ticket_id,
          a.kind,
          a.result,
          a.reason_code,
          a.occurred_at,
          a.received_at,
          COALESCE(
            a.occupancy_day,
            (((a.occurred_at AT TIME ZONE 'UTC') AT TIME ZONE a.tz_name) - (a.rollover_hours * INTERVAL '1 hour'))::date
          ) AS day,
          CASE
            WHEN a.result = :accepted AND a.kind = :admit AND NOT EXISTS (
              SELECT 1 FROM admission_actions rev
              WHERE rev.event_id = a.event_id
                AND rev.reverses_action_id = a.id
                AND rev.kind = :reverse
                AND rev.result = :accepted
            ) THEN 'inside'
            WHEN a.result = :accepted AND a.kind = :exit_kind THEN 'outside'
            WHEN a.result = :accepted AND a.kind = :override AND a.reason_code = 'lead_override_admitted' THEN 'inside'
            WHEN a.result = :accepted AND a.kind = :override AND a.reason_code = 'lead_override_cleared' THEN 'outside'
            ELSE NULL
          END AS target_state
        FROM scoped_actions a
      ),
      state_steps AS (
        SELECT
          event_id,
          day,
          occurred_at,
          received_at,
          id,
          CASE
            WHEN ticket_id IS NULL THEN 0
            WHEN target_state = 'inside' AND COALESCE(
              LAG(target_state) OVER (
                PARTITION BY event_id, day, ticket_id
                ORDER BY occurred_at ASC, received_at ASC, id ASC
              ), 'outside'
            ) <> 'inside' THEN 1
            WHEN target_state = 'outside' AND COALESCE(
              LAG(target_state) OVER (
                PARTITION BY event_id, day, ticket_id
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
          event_id,
          day,
          occurred_at,
          received_at,
          id,
          SUM(delta) OVER (
            PARTITION BY event_id, day
            ORDER BY occurred_at ASC, received_at ASC, id ASC
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
          ) AS running_inside
        FROM state_steps
      ),
      peaks AS (
        SELECT DISTINCT ON (event_id, day)
          event_id,
          day,
          GREATEST(running_inside, 0) AS peak_headcount,
          CASE WHEN running_inside > 0 THEN occurred_at ELSE NULL END AS peak_headcount_at
        FROM running
        ORDER BY event_id, day, running_inside DESC, occurred_at ASC, received_at ASC, id ASC
      ),
      day_totals AS (
        SELECT
          event_id,
          day,
          COUNT(*) FILTER (WHERE result = :accepted AND kind = :admit AND target_state = 'inside' AND reason_code <> 're_entered') AS entries,
          COUNT(*) FILTER (WHERE result = :accepted AND kind = :exit_kind) AS exits,
          COUNT(*) FILTER (WHERE result = :accepted AND kind = :admit AND target_state = 'inside' AND reason_code = 're_entered') AS re_entries,
          COUNT(*) FILTER (WHERE result = :accepted AND kind = :override) AS overrides,
          COUNT(*) FILTER (WHERE result = :conflict) AS conflicts_count
        FROM relevant_actions
        GROUP BY event_id, day
      ),
      final_inside AS (
        SELECT
          event_id,
          day,
          GREATEST(SUM(delta), 0) AS current_headcount,
          MAX(occurred_at) AS max_occurred_at
        FROM state_steps
        GROUP BY event_id, day
      ),
      rollover_steps AS (
        SELECT
          GREATEST(
            (((f.day + 1)::timestamp + (:standard_rollover_hours * INTERVAL '1 hour')) AT TIME ZONE es.tz_name) AT TIME ZONE 'UTC',
            COALESCE(
              CASE WHEN es.session_day = f.day THEN es.session_end_at ELSE NULL END,
              (((f.day + 1)::timestamp + (:standard_rollover_hours * INTERVAL '1 hour')) AT TIME ZONE es.tz_name) AT TIME ZONE 'UTC'
            ),
            f.max_occurred_at + INTERVAL '1 microsecond'
          ) AS occurred_at,
          TIMESTAMP '0001-01-01 00:00:00' AS received_at,
          0::bigint AS id,
          -f.current_headcount AS delta
        FROM final_inside f
        INNER JOIN event_specs es ON es.event_id = f.event_id
        WHERE f.current_headcount > 0
      ),
      combined_steps AS (
        SELECT occurred_at, received_at, id, delta
        FROM state_steps
        WHERE delta <> 0
        UNION ALL
        SELECT occurred_at, received_at, id, delta
        FROM rollover_steps
      ),
      combined_running AS (
        SELECT
          occurred_at,
          received_at,
          id,
          SUM(delta) OVER (
            ORDER BY occurred_at ASC, received_at ASC, id ASC
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
          ) AS running_inside
        FROM combined_steps
      ),
      combined_peak AS (
        SELECT
          GREATEST(running_inside, 0) AS peak_headcount,
          CASE WHEN running_inside > 0 THEN occurred_at ELSE NULL END AS peak_headcount_at
        FROM combined_running
        ORDER BY running_inside DESC, occurred_at ASC, received_at ASC, id ASC
        LIMIT 1
      )
      SELECT
        'day' AS row_kind,
        t.event_id,
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
      LEFT JOIN final_inside f ON f.event_id = t.event_id AND f.day = t.day
      LEFT JOIN peaks p ON p.event_id = t.event_id AND p.day = t.day
      UNION ALL
      SELECT
        'combined_peak' AS row_kind,
        NULL::bigint AS event_id,
        NULL::date AS day,
        0::bigint AS entries,
        0::bigint AS exits,
        0::bigint AS re_entries,
        0::bigint AS overrides,
        0::bigint AS conflicts_count,
        0::bigint AS current_headcount,
        cp.peak_headcount,
        cp.peak_headcount_at
      FROM combined_peak cp
      ORDER BY row_kind DESC, event_id ASC NULLS LAST, day ASC NULLS LAST
    SQL

    def sql_days(target_event, ticket_ids:, event_title:, zone:, now:)
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
      event_service_day = target_event.occupancy_day_for(now).iso8601
      conn.select_all(sanitized).map do |row|
        build_day_row(row, event_id: target_event.id, event_title: event_title, zone: zone,
          current_service_day: event_service_day)
      end
    end

    def sql_multi_event(pass_nights, now:)
      conn = ActiveRecord::Base.connection
      events_by_id = { @event.id => [@event, @zone] }
      pass_nights.each { |night| events_by_id[night.id] = [night, night.event_time_zone] }

      specs_sql = events_by_id.values.map do |ev, ev_zone|
        is_direct = ev.id == @event.id
        session_day = ev.single_session_re_entry? ? ev.starts_at.in_time_zone(ev_zone).to_date : nil
        session_end_at = if ev.single_session_re_entry?
          (ev.ends_at.present? ? (ev.ends_at + 6.hours) : (ev.starts_at + 24.hours)).utc
        end
        ActiveRecord::Base.sanitize_sql_array([
          "(?::bigint, ?::boolean, ?::text, ?::integer, ?::date, ?::timestamp)",
          ev.id.to_i, is_direct, ev_zone.tzinfo.name, ev.re_entry_rollover_hour.to_i, session_day, session_end_at
        ])
      end.join(", ")

      binds = {
        parent_event_id: @event.id.to_i,
        night_event_ids: pass_nights.map { |n| n.id.to_i },
        standard_rollover_hours: Event::RE_ENTRY_ROLLOVER_HOUR,
        admit: AdmissionAction.kinds.fetch("admit"),
        reverse: AdmissionAction.kinds.fetch("reverse"),
        exit_kind: AdmissionAction.kinds.fetch("exit"),
        override: AdmissionAction.kinds.fetch("override"),
        accepted: AdmissionAction.results.fetch("accepted"),
        conflict: AdmissionAction.results.fetch("conflict")
      }
      sql = format(MULTI_EVENT_SQL_TEMPLATE, event_specs_values: specs_sql)
      sanitized = ActiveRecord::Base.sanitize_sql_array([sql, binds])

      service_days_by_id = events_by_id.transform_values { |ev, _| ev.occupancy_day_for(now).iso8601 }
      rows_by_event = Hash.new { |h, k| h[k] = [] }
      combined_peak = nil

      conn.select_all(sanitized).each do |row|
        if row["row_kind"] == "combined_peak"
          peak_time = parse_peak_time(row["peak_headcount_at"], @zone)
          combined_peak = {
            peak_headcount: row["peak_headcount"].to_i,
            peak_headcount_at: peak_time&.iso8601,
            peak_headcount_label: peak_time&.strftime("%-I:%M %p")
          }
        else
          ev_id = row["event_id"].to_i
          ev, ev_zone = events_by_id.fetch(ev_id)
          rows_by_event[ev_id] << build_day_row(
            row,
            event_id: ev_id,
            event_title: ev.title,
            zone: ev_zone,
            current_service_day: service_days_by_id.fetch(ev_id)
          )
        end
      end

      [rows_by_event, combined_peak]
    end

    def build_day_row(row, event_id:, event_title:, zone:, current_service_day:)
      day = row["day"].is_a?(Date) ? row["day"] : Date.iso8601(row["day"].to_s)
      peak_time = parse_peak_time(row["peak_headcount_at"], zone)
      {
        day: day.iso8601,
        label: day.strftime("%b %-d, %Y"),
        event_id: event_id,
        event_title: event_title,
        current_service_day: current_service_day,
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

    def parse_peak_time(peak_raw, zone)
      if peak_raw.is_a?(Time) || peak_raw.is_a?(ActiveSupport::TimeWithZone)
        peak_raw.in_time_zone(zone)
      elsif peak_raw.present?
        ActiveSupport::TimeZone["UTC"].parse(peak_raw.to_s)&.in_time_zone(zone)
      end
    end

    def aggregate_overall(by_day, combined_peak: nil, now: Time.current)
      default_day = @event.occupancy_day_for(now).iso8601
      current_headcount = by_day.group_by { |d| d[:event_id] || @event.id }.sum do |_event_id, event_rows|
        event_day = event_rows.first[:current_service_day] || default_day
        today_rows = event_rows.select { |d| d[:day] == event_day }
        if today_rows.any?
          today_rows.sum { |d| d[:current_headcount].to_i }
        elsif event_rows.last[:day] < event_day
          0
        else
          event_rows.last[:current_headcount].to_i
        end
      end

      peak = if combined_peak
        combined_peak
      else
        peak_row = by_day.max_by { |d| [d[:peak_headcount].to_i, -(Date.iso8601(d[:day]).jd)] }
        {
          peak_headcount: peak_row&.dig(:peak_headcount).to_i,
          peak_headcount_at: peak_row&.dig(:peak_headcount_at),
          peak_headcount_label: peak_row&.dig(:peak_headcount_label)
        }
      end

      {
        entries: by_day.sum { |d| d[:entries].to_i },
        exits: by_day.sum { |d| d[:exits].to_i },
        re_entries: by_day.sum { |d| d[:re_entries].to_i },
        overrides: by_day.sum { |d| d[:overrides].to_i },
        conflicts_count: by_day.sum { |d| d[:conflicts_count].to_i },
        current_headcount: current_headcount,
        peak_headcount: peak.fetch(:peak_headcount),
        peak_headcount_at: peak[:peak_headcount_at],
        peak_headcount_label: peak[:peak_headcount_label]
      }
    end

    def empty_day_row(day, event:, event_title:, now:)
      {
        day: day.iso8601,
        label: day.strftime("%b %-d, %Y"),
        event_id: event.id,
        event_title: event_title,
        current_service_day: event.occupancy_day_for(now).iso8601,
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

    def policy_metadata(now: Time.current)
      {
        mode: @event.re_entry_mode,
        max_count: @event.re_entry_max_count,
        cutoff_time: @event.re_entry_cutoff_time,
        cooldown_minutes: @event.re_entry_cooldown_minutes,
        rollover_hour: @event.re_entry_rollover_hour,
        current_service_day: @event.occupancy_day_for(now).iso8601
      }
    end
  end
end
