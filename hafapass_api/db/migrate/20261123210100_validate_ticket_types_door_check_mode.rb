# frozen_string_literal: true

class ValidateTicketTypesDoorCheckMode < ActiveRecord::Migration[8.1]
  def up
    validate_check_constraint :ticket_types, name: "ticket_types_door_check_mode_valid"
  end

  def down
    # The preceding migration removes the constraint when rolled back.
  end
end
