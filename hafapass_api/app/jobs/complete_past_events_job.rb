# frozen_string_literal: true

# Hourly: marks published events completed six hours after they end, so their
# statements can be finalized without waiting for someone to click "Mark
# completed". Each transition goes through EventLifecycle with no actor; the
# state change and its event.completed audit entry record the system source.
#
# Events without an end time are left for the organizer: EventLifecycle never
# completes an event whose end is unknown.
class CompletePastEventsJob < ApplicationJob
  queue_as :default

  GRACE_PERIOD = 6.hours
  REASON = "Completed automatically 6 hours after the event ended."

  def perform(now: Time.current)
    completed = 0
    Event.published.where(ends_at: ..(now - GRACE_PERIOD)).order(:ends_at, :id).find_each do |event|
      AuditContext.set(source: "system") do
        EventLifecycle.call(event: event, action: :complete, actor: nil, reason: REASON, at: now)
      end
      completed += 1
    rescue EventLifecycle::TransitionError => e
      # Another request may have moved the event since the query; skip it.
      Rails.logger.info({ event: "complete_past_events_skipped", event_id: event.id, error: e.message }.to_json)
    rescue StandardError => e
      # One failing event must not keep the rest stuck in published.
      Sentry.capture_exception(e, extra: { event_id: event.id })
      Rails.logger.error({ event: "complete_past_events_failed", event_id: event.id, error_class: e.class.name }.to_json)
    end
    Rails.logger.info({ event: "complete_past_events", completed: completed }.to_json)
    completed
  end
end
