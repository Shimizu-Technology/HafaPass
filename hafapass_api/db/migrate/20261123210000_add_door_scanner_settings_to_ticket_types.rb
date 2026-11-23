# frozen_string_literal: true

class AddDoorScannerSettingsToTicketTypes < ActiveRecord::Migration[8.1]
  def up
    add_column :ticket_types, :door_check_mode, :string, default: "instant", null: false
    add_column :ticket_types, :door_alert_label, :string, limit: 120
    add_column :ticket_types, :door_instructions, :text
    add_column :ticket_types, :scanner_show_buyer, :boolean, default: false, null: false
    add_check_constraint :ticket_types, "door_check_mode IN ('instant', 'verify')",
      name: "ticket_types_door_check_mode_valid", validate: false
  end

  def down
    remove_check_constraint :ticket_types, name: "ticket_types_door_check_mode_valid"
    remove_columns :ticket_types, :door_check_mode, :door_alert_label, :door_instructions, :scanner_show_buyer
  end
end
