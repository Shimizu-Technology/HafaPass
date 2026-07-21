# frozen_string_literal: true

class EventReminderJob < ApplicationJob
  queue_as :emails

  def perform(reminder_id, scheduled_for)
    reminder = EventReminder.find_by(id: reminder_id)
    return unless reminder

    reminder.with_lock do
      return unless reminder.pending?
      return unless reminder.remind_at.iso8601 == scheduled_for
      return if reminder.remind_at > Time.current

      EmailService.send_event_reminder_async(reminder)
    end
  end
end
