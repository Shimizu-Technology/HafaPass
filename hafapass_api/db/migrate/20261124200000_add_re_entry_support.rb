# frozen_string_literal: true

class AddReEntrySupport < ActiveRecord::Migration[8.1]
  def up
    add_column :events, :re_entry_mode, :string, default: "off", null: false
    add_column :events, :re_entry_max_count, :integer
    add_column :events, :re_entry_cooldown_minutes, :integer

    add_check_constraint :events, "re_entry_mode IN ('off', 'exit_scan', 'cooldown')",
      name: "events_re_entry_mode_valid", validate: false
    add_check_constraint :events, "re_entry_max_count IS NULL OR re_entry_max_count > 0",
      name: "events_re_entry_max_count_positive", validate: false
    add_check_constraint :events, "re_entry_cooldown_minutes IS NULL OR re_entry_cooldown_minutes > 0",
      name: "events_re_entry_cooldown_positive", validate: false

    add_column :tickets, :occupancy_state, :string, default: "outside", null: false
    add_column :tickets, :occupancy_day, :date
    add_column :tickets, :last_entry_at, :datetime
    add_column :tickets, :last_exit_at, :datetime
    add_column :tickets, :last_entry_device_id, :bigint
    add_column :tickets, :re_entry_count, :integer, default: 0, null: false
    add_column :tickets, :re_entry_conflict_flagged, :boolean, default: false, null: false

    add_check_constraint :tickets, "occupancy_state IN ('outside', 'inside')",
      name: "tickets_occupancy_state_valid", validate: false
    add_check_constraint :tickets, "re_entry_count >= 0",
      name: "tickets_re_entry_count_non_negative", validate: false
    add_foreign_key :tickets, :scanner_devices, column: :last_entry_device_id, validate: false

    add_column :admission_actions, :occupancy_day, :date
    add_check_constraint :admission_actions, "kind IN (0, 1, 2, 3)",
      name: "admission_actions_kind_valid_re_entry", validate: false

    add_check_constraint :event_staff_assignments, "role IN (0, 1, 2, 3)",
      name: "event_staff_assignments_role_valid_re_entry", validate: false
  end

  def down
    remove_check_constraint :event_staff_assignments, name: "event_staff_assignments_role_valid_re_entry"
    remove_check_constraint :admission_actions, name: "admission_actions_kind_valid_re_entry"
    remove_column :admission_actions, :occupancy_day

    remove_foreign_key :tickets, column: :last_entry_device_id
    remove_check_constraint :tickets, name: "tickets_re_entry_count_non_negative"
    remove_check_constraint :tickets, name: "tickets_occupancy_state_valid"
    remove_columns :tickets, :occupancy_state, :occupancy_day, :last_entry_at, :last_exit_at,
      :last_entry_device_id, :re_entry_count, :re_entry_conflict_flagged

    remove_check_constraint :events, name: "events_re_entry_cooldown_positive"
    remove_check_constraint :events, name: "events_re_entry_max_count_positive"
    remove_check_constraint :events, name: "events_re_entry_mode_valid"
    remove_columns :events, :re_entry_mode, :re_entry_max_count, :re_entry_cooldown_minutes
  end
end
