# frozen_string_literal: true

class Api::V1::Admin::MaintenanceController < Api::V1::Admin::BaseController
  # Runs the hourly CompletePastEventsJob now: the same 6-hour grace period
  # after an event ends, and one failing event does not stop the rest.
  def complete_past_events
    count = CompletePastEventsJob.perform_now(actor: @current_user)

    render json: { message: "Marked #{count} past events as completed." }
  end
end
