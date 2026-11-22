# frozen_string_literal: true

module Passes
  # Keeps a pass event's ends_at at least as late as its latest included night
  # so storm reschedules or newly added playoff nights never cause an active
  # multi-night pass to look past, close sales early, or complete prematurely.
  class SyncPassEndDate
    SKIPPED_PASS_STATUSES = [:completed, :cancelled, :archived].freeze

    class << self
      def for_pass_event!(pass_event)
        return unless pass_event&.persisted?
        return if pass_event.completed? || pass_event.cancelled? || pass_event.archived?

        latest = latest_included_end_for(pass_event)
        extend_pass_event!(pass_event, latest)
      end

      def for_included_event!(night_event)
        return unless night_event&.persisted?

        pass_event_ids = TicketType
          .joins(:ticket_type_included_events)
          .where(ticket_type_included_events: { included_event_id: night_event.id })
          .distinct
          .pluck(:event_id)
        return if pass_event_ids.empty?

        Event.where(id: pass_event_ids).where.not(status: SKIPPED_PASS_STATUSES).order(:id).each do |pass_event|
          recompute_pass_event!(pass_event)
        end
      end

      private

      def latest_included_end_for(pass_event)
        pass_event.pass_included_events
          .where.not(status: :cancelled)
          .maximum(Arel.sql("COALESCE(events.ends_at, events.starts_at)"))
      end

      def extend_pass_event!(pass_event, target_end)
        return unless target_end
        return if pass_event.ends_at.present? && target_end <= pass_event.ends_at
        return if pass_event.starts_at.present? && target_end <= pass_event.starts_at

        pass_event.update_columns(ends_at: target_end, updated_at: Time.current)
      end

      def recompute_pass_event!(pass_event)
        latest = latest_included_end_for(pass_event)
        target_end = if latest
          [pass_event.starts_at, latest].compact.max
        elsif pass_event.pass_only_event?
          # Zero non-cancelled included nights remain: drop any stale storm-extended
          # ends_at while keeping ends_at strictly after starts_at for chronological_event_times.
          pass_event.starts_at ? pass_event.starts_at + 1.second : Time.current
        end
        return unless target_end
        return if pass_event.ends_at == target_end

        pass_event.update_columns(ends_at: target_end, updated_at: Time.current)
      end
    end
  end
end
