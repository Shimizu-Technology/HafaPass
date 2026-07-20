# frozen_string_literal: true

class Api::V1::Admin::MaintenanceController < Api::V1::Admin::BaseController
  def complete_past_events
    events = Event.published.where("ends_at <= ?", Time.current)
    count = 0
    events.find_each do |event|
      EventLifecycle.call(event: event, action: :complete, actor: @current_user)
      count += 1
    end

    render json: { message: "Marked #{count} past events as completed." }
  end
end
