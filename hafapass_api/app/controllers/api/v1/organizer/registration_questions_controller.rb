# frozen_string_literal: true

class Api::V1::Organizer::RegistrationQuestionsController < Api::V1::Organizer::EventResourcesController
  def index
    render json: { registration_questions: event.registration_questions.order(:position, :id).map { |item| serialize(item) } }
  end

  def create
    render_record(event.registration_questions.build(record_params), status: :created)
  end

  def update
    item = event.registration_questions.find(params[:id])
    item.assign_attributes(record_params)
    render_record(item)
  end

  def destroy
    destroy_record(event.registration_questions.find(params[:id]))
  end

  private

  def record_params
    params.permit(:prompt, :kind, :required, :position, :active, options: [])
  end

  def serialize(item)
    item.as_json(only: [:id, :prompt, :kind, :required, :options, :position, :active])
  end
end
