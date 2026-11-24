# frozen_string_literal: true

module Admissions
  # Computes re-entry & headcount metrics (entries, exits, re-entries, overrides,
  # current headcount, peak headcount + timestamp) overall and per day.
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
      scope = target_event.admission_actions.order(:occurred_at, :received_at, :id)
      scope = scope.where(ticket_id: ticket_ids) unless ticket_ids.nil?
      actions = scope.select(:id, :ticket_id, :kind, :result, :reason_code, :occurred_at, :received_at, :occupancy_day, :reverses_action_id).to_a

      by_day = compute_days(actions, event_id: target_event.id, event_title: nil)
      overall = compute_summary(actions, by_day: by_day)
      overall.merge(policy_metadata)
    end

    def call_multi_night_pass(pass_nights)
      pass_parent_ids = @event.tickets.joins(:ticket_type).where(parent_ticket_id: nil, ticket_types: { is_pass: true }).select(:id)
      all_actions = []
      by_day = pass_nights.flat_map do |night|
        night_zone = night.event_time_zone
        night_ticket_ids = Ticket.where(event_id: night.id, parent_ticket_id: pass_parent_ids).select(:id)
        actions = night.admission_actions.where(ticket_id: night_ticket_ids)
          .order(:occurred_at, :received_at, :id)
          .select(:id, :ticket_id, :kind, :result, :reason_code, :occurred_at, :received_at, :occupancy_day, :reverses_action_id)
          .to_a
        all_actions.concat(actions)
        days = compute_days(actions, event_id: night.id, event_title: night.title, zone: night_zone)
        if days.empty? && night.starts_at
          night_day = night.starts_at.in_time_zone(night_zone).to_date
          days = [empty_day_row(night_day, event_id: night.id, event_title: night.title)]
        end
        days
      end

      overall = compute_summary(all_actions, by_day: by_day)
      overall.merge(policy_metadata)
    end

    def compute_days(actions, event_id:, event_title:, zone: @zone)
      grouped = actions.group_by { |action| action.occupancy_day || action.occurred_at.in_time_zone(zone).to_date }
      grouped.keys.sort.map do |day|
        day_actions = grouped[day]
        stats = simulate_occupancy(day_actions, zone: zone)
        stats.merge(
          day: day.iso8601,
          label: day.strftime("%b %-d, %Y"),
          event_id: event_id,
          event_title: event_title
        ).compact
      end
    end

    def compute_summary(actions, by_day:)
      overall = simulate_occupancy(actions, zone: @zone)
      overall.merge(by_day: by_day)
    end

    def simulate_occupancy(actions, zone:)
      reversed_ids = actions.select { |a| a.kind_reverse? && a.result_accepted? }.filter_map(&:reverses_action_id).to_set
      entries = 0
      re_entries = 0
      exits = 0
      overrides = 0
      conflicts = 0
      inside_state = {}
      current_inside = 0
      peak_headcount = 0
      peak_at = nil

      actions.each do |action|
        if action.result_conflict?
          conflicts += 1
          next
        end
        next unless action.result_accepted?

        case action.kind
        when "admit"
          next if reversed_ids.include?(action.id)

          if action.reason_code == "re_entered"
            re_entries += 1
          else
            entries += 1
          end
          if action.ticket_id && !inside_state[action.ticket_id]
            inside_state[action.ticket_id] = true
            current_inside += 1
          end
        when "exit"
          exits += 1
          if action.ticket_id && inside_state[action.ticket_id]
            inside_state[action.ticket_id] = false
            current_inside -= 1
          end
        when "override"
          overrides += 1
          if action.reason_code == "lead_override_admitted"
            if action.ticket_id && !inside_state[action.ticket_id]
              inside_state[action.ticket_id] = true
              current_inside += 1
            end
          elsif action.reason_code == "lead_override_cleared"
            if action.ticket_id && inside_state[action.ticket_id]
              inside_state[action.ticket_id] = false
              current_inside -= 1
            end
          end
        end

        if current_inside > peak_headcount
          peak_headcount = current_inside
          peak_at = action.occurred_at
        end
      end

      peak_local = peak_at&.in_time_zone(zone)
      {
        entries: entries,
        exits: exits,
        re_entries: re_entries,
        overrides: overrides,
        conflicts_count: conflicts,
        current_headcount: current_inside,
        peak_headcount: peak_headcount,
        peak_headcount_at: peak_local&.iso8601,
        peak_headcount_label: peak_local&.strftime("%-I:%M %p")
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
        cooldown_minutes: @event.re_entry_cooldown_minutes
      }
    end
  end
end
