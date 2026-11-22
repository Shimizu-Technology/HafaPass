# frozen_string_literal: true

class Api::V1::Organizer::RegistrationQuestionsController < Api::V1::Organizer::EventResourcesController
  GRADUATION_YEAR = { prompt: "Graduation Year", kind: "number", required: true,
    validation_rules: { "min" => 1950, "max" => 2035 }, help_text: "4-digit year, for example 1998" }.freeze
  # One-click starter sets. A template given a ticket type asks its questions
  # only when that ticket type is in the cart.
  TEMPLATES = {
    "fd_team_registration" => [
      { prompt: "Class Name", kind: "short_text", required: true, help_text: "For example: Class of 1998" },
      GRADUATION_YEAR,
      { prompt: "Division", kind: "selection", required: false, options: %w[Maroon Gold Platinum Special] },
      { prompt: "Team Captain Phone", kind: "phone", required: false }
    ],
    "alumni_door_verification" => [GRADUATION_YEAR.merge(scope: "ticket", show_on_scanner: true)],
    "merch_shirt_size" => [{ prompt: "Shirt Size", kind: "selection", required: false, options: %w[S M L XL 2XL] }]
  }.freeze

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

  # Adds a template's questions in one transaction. Questions already on the
  # event (same prompt and scope) are skipped, so a second click is harmless.
  # Alumni Door Verification also asks for each attendee's name on the chosen
  # ticket type, which needs inventory access.
  def apply_template
    definitions = TEMPLATES[params[:template].to_s]
    return render json: { error: "Choose a starter template" }, status: :unprocessable_entity unless definitions

    ticket_type = nil
    if params[:ticket_type_id].present?
      ticket_type = event.ticket_types.find_by(id: params[:ticket_type_id])
      return render json: { error: "Ticket type not found" }, status: :not_found unless ticket_type
    end
    enables_attendee_names = params[:template] == "alumni_door_verification" && ticket_type
    return if enables_attendee_names && !authorize_organization!(:manage_inventory, event: event)

    created = []
    skipped = []
    RegistrationQuestion.transaction do
      event.lock!("FOR NO KEY UPDATE")
      existing = event.registration_questions.where(active: true).to_a
      position = (event.registration_questions.maximum(:position) || -1) + 1
      definitions.each do |definition|
        scope = definition.fetch(:scope, "order")
        if existing.any? { |question| question.scope == scope && question.prompt.casecmp?(definition[:prompt]) }
          skipped << definition[:prompt]
          next
        end

        created << event.registration_questions.create!(
          definition.merge(scope: scope, position: position, ticket_type_ids: ticket_type ? [ticket_type.id] : [])
        )
        position += 1
      end
      if enables_attendee_names && !ticket_type.collects_attendee_name?
        ticket_type.lock!
        ticket_type.update!(attendee_info_mode: "name_only")
      end
    end
    render json: {
      registration_questions: created.map { |item| serialize(item) },
      skipped_prompts: skipped,
      ticket_type: ticket_type && { id: ticket_type.id, attendee_info_mode: ticket_type.reload.attendee_info_mode }
    }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  private

  def record_params
    attributes = params.permit(:prompt, :kind, :required, :position, :active, :scope, :show_on_scanner, :help_text,
      options: [], ticket_type_ids: [], validation_rules: [:min, :max]).to_h
    attributes["ticket_type_ids"] = [] if attributes.key?("ticket_type_ids") && attributes["ticket_type_ids"].nil?
    attributes["validation_rules"] = attributes["validation_rules"].to_h.compact_blank if attributes.key?("validation_rules")
    attributes["help_text"] = attributes["help_text"].to_s.strip.presence if attributes.key?("help_text")
    attributes
  end

  def serialize(item)
    item.as_json(only: [:id, :prompt, :kind, :required, :options, :position, :active, :scope, :ticket_type_ids,
      :show_on_scanner, :help_text, :validation_rules])
  end
end
