# frozen_string_literal: true

class Api::V1::Organizer::EventWaiversController < Api::V1::Organizer::EventResourcesController
  def index
    render json: { event_waivers: event.event_waivers.order(:id).map { |item| serialize(item) } }
  end

  def create
    render_record(event.event_waivers.build(record_params), status: :created)
  end

  def update
    item = event.event_waivers.find(params[:id])
    item.assign_attributes(record_params)
    render_record(item)
  end

  def destroy
    destroy_record(event.event_waivers.find(params[:id]))
  end

  private

  def record_params
    params.permit(:title, :body, :version, :required, :active)
  end

  def serialize(item)
    item.as_json(only: [:id, :title, :body, :version, :content_digest, :required, :active])
  end
end
