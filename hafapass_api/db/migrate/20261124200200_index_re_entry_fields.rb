# frozen_string_literal: true

class IndexReEntryFields < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :tickets, [:event_id, :occupancy_state],
      name: "index_tickets_on_event_id_and_occupancy_state",
      algorithm: :concurrently
    add_index :tickets, :last_entry_device_id,
      name: "index_tickets_on_last_entry_device_id",
      where: "last_entry_device_id IS NOT NULL",
      algorithm: :concurrently
    add_index :admission_actions, [:event_id, :occupancy_day, :occurred_at],
      name: "index_admission_actions_on_event_day_occurred_at",
      algorithm: :concurrently
  end
end
