# frozen_string_literal: true

module Passes
  # Keeps a pass event's ends_at at least as late as its latest included night
  # so storm reschedules or newly added playoff nights never cause an active
  # multi-night pass to look past, close sales early, or complete prematurely.
  class SyncPassEndDate
    class << self
      def for_pass_event!(pass_event)
        return unless pass_event&.persisted?
        return if pass_event.cancelled? || pass_event.archived?

        latest = latest_included_end_for(pass_event)
        extend_pass_event!(pass_event, latest)
      end

      def for_included_event!(night_event)
        return unless night_event&.persisted?

        night_end = night_event.ends_at || night_event.starts_at
        return unless night_end

        pass_event_ids = TicketType
          .joins(:ticket_type_included_events)
          .where(ticket_type_included_events: { included_event_id: night_event.id })
          .distinct
          .pluck(:event_id)
        return if pass_event_ids.empty?

        Event.where(id: pass_event_ids).where.not(status: [:cancelled, :archived]).order(:id).each do |pass_event|
          latest = [night_end, latest_included_end_for(pass_event)].compact.max
          extend_pass_event!(pass_event, latest)
        end
      end

      private

      def latest_included_end_for(pass_event)
        pass_event.pass_included_events.maximum(Arel.sql("COALESCE(events.ends_at, events.starts_at)"))
      end

      def extend_pass_event!(pass_event, target_end)
        return unless target_end
        return if pass_event.ends_at.present? && target_end <= pass_event.ends_at
        return if pass_event.starts_at.present? && target_end <= pass_event.starts_at

        pass_event.update!(ends_at: target_end)
      end
    end
  end
end
