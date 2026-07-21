# frozen_string_literal: true

class Api::V1::Organizer::EventResourcesController < Api::V1::Organizer::BaseController
  before_action :set_event

  private

  attr_reader :event

  def set_event
    @event = find_organization_event(params[:event_id])
    authorize_organization!(resource_permission, event: @event) if @event
  end

  def resource_permission
    :manage_events
  end

  def render_record(record, status: :ok)
    if record.save
      render json: serialize(record), status: status
    else
      render json: { errors: record.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy_record(record)
    if record.destroy
      head :no_content
    else
      render json: { errors: record.errors.full_messages }, status: :unprocessable_entity
    end
  end
end
