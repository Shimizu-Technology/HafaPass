# frozen_string_literal: true

module Admissions
  class DoorPayload
    VALUE_LIMIT = 80

    def self.call(ticket)
      new(ticket).as_json
    end

    def initialize(ticket)
      @ticket = ticket
    end

    def as_json
      type = @ticket.ticket_type
      attendee = @ticket.attendee_name.to_s.strip.presence || "Guest"
      payload = {
        attendee_name: attendee,
        ticket_type_name: type.name,
        door_check_mode: type.door_check_mode,
        door_alert_label: type.door_alert_label,
        door_instructions: type.door_instructions,
        door_fields: door_fields
      }
      if type.scanner_show_buyer?
        buyer = @ticket.order.buyer_name.to_s.strip.presence
        payload[:buyer_name] = buyer if buyer && !buyer.casecmp?(attendee)
      end
      payload
    end

    private

    def door_fields
      @ticket.effective_registration_responses
        .select do |response|
          question = response.registration_question
          question.show_on_scanner? && question.applies_to_ticket_type?(@ticket.ticket_type_id)
        end
        .sort_by { |response| [response.ticket_id ? 0 : 1, response.registration_question.position, response.registration_question_id] }
        .filter_map do |response|
          value = format_answer(response.answer, response.registration_question.kind)
          { label: response.registration_question.prompt, value: value } if value
        end
    end

    def format_answer(answer, kind)
      answer = answer["value"] if answer.is_a?(Hash)
      value = case kind
      when "checkbox" then "Yes" if answer == true
      when "multi_select" then Array(answer).grep(String).filter_map { |choice| choice.strip.presence }.join(", ")
      else answer.to_s.strip if answer.is_a?(String) || answer.is_a?(Numeric)
      end
      value.presence&.truncate(VALUE_LIMIT, omission: "…")
    end
  end
end
