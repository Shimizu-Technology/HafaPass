# frozen_string_literal: true

class ValidateReEntryConstraints < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    validate_check_constraint :events, name: "events_re_entry_mode_valid"
    validate_check_constraint :events, name: "events_re_entry_max_count_positive"
    validate_check_constraint :events, name: "events_re_entry_cooldown_positive"

    validate_check_constraint :tickets, name: "tickets_occupancy_state_valid"
    validate_check_constraint :tickets, name: "tickets_re_entry_count_non_negative"
    validate_foreign_key :tickets, column: :last_entry_device_id

    validate_check_constraint :admission_actions, name: "admission_actions_kind_valid_re_entry"
    validate_check_constraint :event_staff_assignments, name: "event_staff_assignments_role_valid_re_entry"

    remove_check_constraint :admission_actions, name: "admission_actions_kind_valid", if_exists: true
    remove_check_constraint :event_staff_assignments, name: "event_staff_assignments_role_valid", if_exists: true
  end

  def down
    add_check_constraint :event_staff_assignments, "role IN (0, 1, 2)",
      name: "event_staff_assignments_role_valid", validate: false
    add_check_constraint :admission_actions, "kind IN (0, 1)",
      name: "admission_actions_kind_valid", validate: false
  end
end
