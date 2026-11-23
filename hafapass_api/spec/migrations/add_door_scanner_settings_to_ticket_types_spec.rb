# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261123210000_add_door_scanner_settings_to_ticket_types")
require Rails.root.join("db/migrate/20261123210100_validate_ticket_types_door_check_mode")

RSpec.describe AddDoorScannerSettingsToTicketTypes do
  it "rolls back and re-applies the door columns, defaults, and check constraint on existing ticket types" do
    type = create(:ticket_type, door_check_mode: "verify", door_alert_label: "Check ID")
    connection = TicketType.connection
    name = "ticket_types_door_check_mode_valid"
    validation = ValidateTicketTypesDoorCheckMode.new

    ActiveRecord::Migration.suppress_messages do
      validation.migrate(:down)
      described_class.new.migrate(:down)
      %i[door_check_mode door_alert_label door_instructions scanner_show_buyer].each do |column|
        expect(connection.column_exists?(:ticket_types, column)).to be(false)
      end
      expect(connection.check_constraint_exists?(:ticket_types, name: name)).to be(false)
      described_class.new.migrate(:up)
      # The fixture's enclosing transaction retains the earlier DDL lock.
      # A real migration run validates in a separate transaction.
      validation.safety_assured { validation.migrate(:up) }
    end

    expect(type.reload).to have_attributes(door_check_mode: "instant", door_alert_label: nil,
      door_instructions: nil, scanner_show_buyer: false)
    expect(connection.check_constraints(:ticket_types).find { |constraint| constraint.name == name }).to be_validate
    expect do
      TicketType.transaction(requires_new: true) { type.update_columns(door_check_mode: "unknown") }
    end.to raise_error(ActiveRecord::StatementInvalid, /#{name}/)
  end
end
