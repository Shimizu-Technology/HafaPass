# frozen_string_literal: true

class Api::V1::Me::EventRemindersController < ApplicationController
  def index
    reminders = current_user.event_reminders.includes(:event).order(:remind_at)
    render json: { reminders: reminders.map { |reminder| reminder_json(reminder) } }
  end

  def create
    return render json: { error: "Add an email address before creating reminders" }, status: :unprocessable_entity if current_user.email.blank?

    event = Event.discoverable.find(params[:event_id])
    remind_at = parse_remind_at(event)
    reminder = current_user.event_reminders.find_or_initialize_by(event: event)
    reminder.assign_attributes(remind_at: remind_at, status: :pending, sent_at: nil)
    reminder.save!
    EventReminderJob.set(wait_until: remind_at).perform_later(reminder.id, remind_at.iso8601)
    render json: reminder_json(reminder), status: :created
  rescue ArgumentError
    render json: { error: "remind_at must be a valid future time before the event" }, status: :unprocessable_entity
  end

  def destroy
    reminder = current_user.event_reminders.find_by!(event_id: params[:event_id])
    reminder.update!(status: :cancelled)
    head :no_content
  end

  private

  def parse_remind_at(event)
    value = params[:remind_at].present? ? Time.iso8601(params[:remind_at].to_s) : event.starts_at - 1.day
    value = 5.minutes.from_now if value <= Time.current && event.starts_at > 5.minutes.from_now
    raise ArgumentError unless value > Time.current && value < event.starts_at

    value
  end

  def reminder_json(reminder)
    { id: reminder.id, event_id: reminder.event_id, status: reminder.status, remind_at: reminder.remind_at,
      event: { title: reminder.event.title, slug: reminder.event.slug, starts_at: reminder.event.starts_at,
        timezone: reminder.event.timezone } }
  end
end
