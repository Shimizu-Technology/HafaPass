# frozen_string_literal: true

# Hourly: marks published events completed six hours after they end, so their
# statements can be finalized without waiting for someone to click "Mark
# completed". Each transition goes through EventLifecycle with no actor; the
# state change and its event.completed audit entry record the system source.
#
# Events without an end time are left for the organizer: EventLifecycle never
# completes an event whose end is unknown.
#
# Admin -> Maintenance runs it synchronously with the administrator as actor
# (Api::V1::Admin::MaintenanceController), with the same grace period and
# per-event isolation.
class CompletePastEventsJob < ApplicationJob
  queue_as :default

  GRACE_PERIOD = 6.hours
  REASON = "Completed automatically 6 hours after the event ended."

  def perform(now: Time.current, actor: nil)
    completed = 0
    # find_each batches by primary key; an explicit order would be ignored.
    Event.published.where(ends_at: ..(now - GRACE_PERIOD)).find_each do |event|
      if actor
        EventLifecycle.call(event: event, action: :complete, actor: actor, reason: REASON, at: now)
      else
        AuditContext.set(source: "system") do
          EventLifecycle.call(event: event, action: :complete, actor: nil, reason: REASON, at: now)
        end
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
