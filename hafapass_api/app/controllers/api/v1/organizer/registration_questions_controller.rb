# frozen_string_literal: true

class Api::V1::Organizer::RegistrationQuestionsController < Api::V1::Organizer::EventResourcesController
  GRADUATION_YEAR = { prompt: "Graduation Year", kind: "number", required: true,
    validation_rules: { "min" => 1950, "max" => 2035, "integer" => true }, help_text: "4-digit year, for example 1998" }.freeze
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
  # Templates that set per-ticket attendee details on their ticket type.
  TICKET_TYPE_TEMPLATES = %w[alumni_door_verification].freeze

  # Settings a matching question must share with the template, by the name
  # shown to organizers in a conflict.
  TEMPLATE_SETTINGS = {
    "answer type" => ->(definition) { definition[:kind] },
    "required" => ->(definition) { definition[:required] == true },
    "door scanner" => ->(definition) { definition.fetch(:show_on_scanner, false) },
    "choices" => ->(definition) { definition.fetch(:options, []) },
    "number limits" => ->(definition) { definition.fetch(:validation_rules, {}).stringify_keys }
  }.freeze
  QUESTION_SETTINGS = {
    "answer type" => :kind, "required" => :required, "door scanner" => :show_on_scanner,
    "choices" => :options, "number limits" => :validation_rules
  }.freeze

  class TemplateConflict < StandardError; end
  class TemplateForbidden < StandardError; end

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

  # The event lock serializes with checkout and payment completion, so a
  # question cannot disappear between a buyer answering it and their tickets
  # being issued (see RegistrationQuestion#referenced_by_pending_checkout?).
  def destroy
    RegistrationQuestion.transaction do
      event.lock!("FOR NO KEY UPDATE")
      item = event.registration_questions.find(params[:id])
      destroy_record(item)
      raise ActiveRecord::Rollback unless item.destroyed?
    end
  end

  # Adds a template's questions in one transaction. A matching question (same
  # prompt and scope) that already covers the chosen ticket type is skipped,
  # one limited to other ticket types gains this one, and a match that cannot
  # be combined (different answer type, or all-ticket vs per-ticket-type)
  # returns 409 without changing anything. Alumni Door Verification requires a
  # ticket type and also asks for each attendee's name on it, which needs
  # inventory access.
  def apply_template
    template = params[:template].to_s
    definitions = TEMPLATES[template]
    return render json: { error: "Choose a starter template" }, status: :unprocessable_entity unless definitions

    ticket_type = nil
    if params[:ticket_type_id].present?
      ticket_type = event.ticket_types.find_by(id: params[:ticket_type_id])
      return render json: { error: "Ticket type not found" }, status: :not_found unless ticket_type
    elsif TICKET_TYPE_TEMPLATES.include?(template)
      return render json: { error: "Choose the ticket type this template is for" }, status: :unprocessable_entity
    end
    enables_attendee_names = TICKET_TYPE_TEMPLATES.include?(template)
    return if enables_attendee_names && !authorize_organization!(:manage_inventory, event: event)

    created = []
    updated = []
    skipped = []
    RegistrationQuestion.transaction do
      # docs/LOCKING.md: organization, then event, then ticket type.
      event.organization.lock!("FOR NO KEY UPDATE")
      # Membership and role changes take the organization lock, so authority
      # checked here cannot be revoked before this transaction commits.
      ensure_template_authority!(enables_attendee_names)
      event.lock!("FOR NO KEY UPDATE")
      # Locking reloads the ticket type, so a concurrent upgrade to name and
      # email is seen and never downgraded below.
      ticket_type&.lock!("FOR NO KEY UPDATE")
      plan = template_plan(definitions, ticket_type)
      position = (event.registration_questions.maximum(:position) || -1) + 1
      plan.each do |action, definition, existing|
        case action
        when :skip then skipped << definition[:prompt]
        when :extend
          existing.update!(ticket_type_ids: existing.ticket_type_ids | [ticket_type.id])
          updated << existing
        when :create
          created << event.registration_questions.create!(definition.merge(
            scope: definition.fetch(:scope, "order"), position: position, ticket_type_ids: ticket_type ? [ticket_type.id] : []
          ))
          position += 1
        end
      end
      apply_alumni_ticket_settings!(ticket_type) if enables_attendee_names
    end
    render json: {
      registration_questions: created.map { |item| serialize(item) },
      updated_questions: updated.map { |item| serialize(item) },
      skipped_prompts: skipped,
      ticket_type: ticket_type && { id: ticket_type.id, attendee_info_mode: ticket_type.attendee_info_mode,
        door_check_mode: ticket_type.door_check_mode }
    }, status: :created
  rescue TemplateConflict => e
    render json: { error: e.message }, status: :conflict
  rescue TemplateForbidden
    render json: { error: "You do not have permission to perform this action" }, status: :forbidden
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  private

  def apply_alumni_ticket_settings!(ticket_type)
    ticket_type.attendee_info_mode = "name_only" unless ticket_type.collects_attendee_name?
    if ticket_type.door_check_mode == "instant" && ticket_type.door_alert_label.blank?
      ticket_type.door_check_mode = "verify"
      ticket_type.door_alert_label = "FREE ALUMNI — CHECK ID"
      ticket_type.door_instructions = ticket_type.door_instructions.presence ||
        "Check alumni ID or confirm graduation year before admitting."
    end
    ticket_type.save! if ticket_type.changed?
  end

  def ensure_template_authority!(enables_attendee_names)
    permissions = [:manage_events, (:manage_inventory if enables_attendee_names)].compact
    allowed = permissions.all? do |permission|
      OrganizationAuthorization.allowed?(user: current_user, organization: event.organization, permission: permission, event: event)
    end
    raise TemplateForbidden unless allowed
  end

  def template_plan(definitions, ticket_type)
    existing = event.registration_questions.where(active: true).order(:position, :id).to_a
    definitions.map do |definition|
      scope = definition.fetch(:scope, "order")
      matches = existing.select { |question| question.scope == scope && question.prompt.casecmp?(definition[:prompt]) }
      next [:create, definition] if matches.empty?

      covered_matches = matches.select do |question|
        question.ticket_type_ids.empty? || (ticket_type && question.ticket_type_ids.include?(ticket_type.id))
      end
      if covered_matches.any?
        next [:skip, definition] if covered_matches.any? { |question| template_differences(question, definition).empty? }

        differences = template_differences(covered_matches.first, definition)
        raise TemplateConflict, "\"#{definition[:prompt]}\" already exists with different settings (#{differences.join(', ')}). " \
          "Rename or remove it, then add the template again."
      end

      compatible = matches.find { |question| template_differences(question, definition).empty? }
      next [:extend, definition, compatible] if compatible && ticket_type

      if compatible.nil?
        differences = template_differences(matches.first, definition)
        raise TemplateConflict, "\"#{definition[:prompt]}\" already exists with different settings (#{differences.join(', ')}). " \
          "Rename or remove it, then add the template again."
      end
      raise TemplateConflict, "\"#{definition[:prompt]}\" is already limited to specific ticket types. " \
        "Choose a ticket type for this template or edit the existing question."
    end
  end

  def template_differences(question, definition)
    TEMPLATE_SETTINGS.filter_map do |label, expected|
      label unless question.public_send(QUESTION_SETTINGS.fetch(label)) == expected.call(definition)
    end
  end

  # Rails collapses a JSON [null] into [] before params are read, which would
  # silently widen the question to every ticket type, so a JSON body is read
  # as sent.
  def raw_ticket_type_ids
    if request.media_type == "application/json"
      body = begin
        JSON.parse(request.raw_post)
      rescue JSON::ParserError
        nil
      end
      return body["ticket_type_ids"] if body.is_a?(Hash) && body.key?("ticket_type_ids")
    end
    params[:ticket_type_ids]
  end

  def record_params
    attributes = params.permit(:prompt, :kind, :required, :position, :active, :scope, :show_on_scanner, :help_text,
      options: [], validation_rules: [:min, :max, :integer]).to_h
    if params.key?(:ticket_type_ids)
      # Passed through unfiltered: the model rejects anything but a list of
      # IDs rather than dropping bad items and widening the question.
      raw = raw_ticket_type_ids
      attributes["ticket_type_ids"] = if raw.nil?
        []
      elsif raw.is_a?(Array) && raw.all? { |id| id.is_a?(String) || id.is_a?(Integer) }
        raw
      else
        "invalid"
      end
    end
    attributes["validation_rules"] = attributes["validation_rules"].to_h.compact_blank if attributes.key?("validation_rules")
    attributes["help_text"] = attributes["help_text"].to_s.strip.presence if attributes.key?("help_text")
    attributes
  end

  def serialize(item)
    item.as_json(only: [:id, :prompt, :kind, :required, :options, :position, :active, :scope, :ticket_type_ids,
      :show_on_scanner, :help_text, :validation_rules])
  end
end
