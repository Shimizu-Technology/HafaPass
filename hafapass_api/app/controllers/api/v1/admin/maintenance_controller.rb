# frozen_string_literal: true

class Api::V1::Admin::MaintenanceController < Api::V1::Admin::BaseController
  def complete_past_events
    cutoff = 6.hours.ago
    events = Event.published.where("starts_at < ?", cutoff)
    count = events.count
    events.update_all(status: Event.statuses[:completed])

    render json: { message: "Marked #{count} past events as completed." }
  end
end
