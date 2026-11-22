# frozen_string_literal: true

class AddMultiNightPasses < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_column :ticket_types, :is_pass, :boolean, default: false, null: false

    create_table :ticket_type_included_events do |t|
      t.references :ticket_type, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :included_event, null: false, foreign_key: { to_table: :events, on_delete: :restrict }
      t.integer :position, default: 0, null: false

      t.timestamps
    end

    add_index :ticket_type_included_events, [:ticket_type_id, :included_event_id],
      unique: true, name: "index_ticket_type_included_events_uniqueness"
    add_check_constraint :ticket_type_included_events, "position >= 0",
      name: "chk_ticket_type_included_events_position_nonnegative"

    add_column :tickets, :parent_ticket_id, :bigint
    add_index :tickets, :parent_ticket_id, algorithm: :concurrently
    add_index :tickets, [:parent_ticket_id, :event_id],
      unique: true,
      where: "parent_ticket_id IS NOT NULL",
      name: "index_tickets_on_parent_ticket_id_and_event_id",
      algorithm: :concurrently
    add_foreign_key :tickets, :tickets, column: :parent_ticket_id, on_delete: :restrict, validate: false
    validate_foreign_key :tickets, :tickets, column: :parent_ticket_id
    add_check_constraint :tickets, "parent_ticket_id IS NULL OR order_item_id IS NULL",
      name: "chk_tickets_pass_child_no_order_item", validate: false
    validate_check_constraint :tickets, name: "chk_tickets_pass_child_no_order_item"
  end

  def down
    remove_check_constraint :tickets, name: "chk_tickets_pass_child_no_order_item"
    remove_foreign_key :tickets, column: :parent_ticket_id
    remove_index :tickets, name: "index_tickets_on_parent_ticket_id_and_event_id", algorithm: :concurrently, if_exists: true
    remove_index :tickets, :parent_ticket_id, algorithm: :concurrently, if_exists: true
    remove_column :tickets, :parent_ticket_id

    drop_table :ticket_type_included_events

    remove_column :ticket_types, :is_pass
  end
end
