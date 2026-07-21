# frozen_string_literal: true

class CreateAssignedSeating < ActiveRecord::Migration[8.1]
  def change
    create_table :venue_layouts do |t|
      t.references :venue, null: false, foreign_key: { on_delete: :restrict }
      t.references :organization, null: false, foreign_key: { on_delete: :restrict }
      t.string :name, null: false
      t.integer :version, null: false, default: 1
      t.integer :status, null: false, default: 0
      t.integer :renderer, null: false, default: 0
      t.string :provider_chart_key
      t.timestamps
    end
    add_index :venue_layouts, [:organization_id, :venue_id, :name, :version], unique: true,
      name: "index_venue_layouts_on_owner_venue_name_version"
    add_check_constraint :venue_layouts, "version > 0", name: "venue_layouts_version_positive"
    add_check_constraint :venue_layouts, "status IN (0, 1, 2)", name: "venue_layouts_status_valid"
    add_check_constraint :venue_layouts, "renderer IN (0, 1)", name: "venue_layouts_renderer_valid"

    create_table :seating_sections do |t|
      t.references :venue_layout, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.string :code, null: false
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :seating_sections, [:venue_layout_id, :code], unique: true

    create_table :seating_price_zones do |t|
      t.references :venue_layout, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.string :code, null: false
      t.string :color, null: false, default: "#2563EB"
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :seating_price_zones, [:venue_layout_id, :code], unique: true

    create_table :seating_rows do |t|
      t.references :seating_section, null: false, foreign_key: { on_delete: :cascade }
      t.string :label, null: false
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :seating_rows, [:seating_section_id, :label], unique: true

    create_table :venue_seats do |t|
      t.references :seating_row, null: false, foreign_key: { on_delete: :cascade }
      t.references :seating_price_zone, null: false, foreign_key: { on_delete: :restrict }
      t.string :label, null: false
      t.integer :position, null: false
      t.decimal :x, precision: 10, scale: 3
      t.decimal :y, precision: 10, scale: 3
      t.integer :accessibility_kind, null: false, default: 0
      t.string :companion_group
      t.boolean :obstructed_view, null: false, default: false
      t.string :view_note
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :venue_seats, [:seating_row_id, :label], unique: true
    add_index :venue_seats, [:seating_row_id, :position], unique: true
    add_check_constraint :venue_seats, "position >= 0", name: "venue_seats_position_nonnegative"
    add_check_constraint :venue_seats, "accessibility_kind IN (0, 1, 2, 3)",
      name: "venue_seats_accessibility_kind_valid"

    create_table :event_seating_configurations do |t|
      t.references :event, null: false, foreign_key: { on_delete: :restrict }, index: { unique: true }
      t.references :venue_layout, null: false, foreign_key: { on_delete: :restrict }
      t.integer :status, null: false, default: 0
      t.string :provider_event_key
      t.datetime :activated_at
      t.timestamps
    end
    add_check_constraint :event_seating_configurations, "status IN (0, 1, 2)",
      name: "event_seating_configurations_status_valid"

    create_table :event_price_zones do |t|
      t.references :event_seating_configuration, null: false, foreign_key: { on_delete: :cascade },
        index: { name: "index_event_price_zones_on_configuration_id" }
      t.references :seating_price_zone, null: false, foreign_key: { on_delete: :restrict }
      t.references :ticket_type, null: false, foreign_key: { on_delete: :restrict }
      t.timestamps
    end
    add_index :event_price_zones, [:event_seating_configuration_id, :seating_price_zone_id], unique: true,
      name: "index_event_price_zones_on_configuration_and_zone"

    create_table :event_seats do |t|
      t.references :event_seating_configuration, null: false, foreign_key: { on_delete: :restrict },
        index: { name: "index_event_seats_on_configuration_id" }
      t.references :venue_seat, null: false, foreign_key: { on_delete: :restrict }
      t.references :ticket_type, null: false, foreign_key: { on_delete: :restrict }
      t.integer :operational_status, null: false, default: 0
      t.datetime :general_release_at
      t.string :status_reason
      t.timestamps
    end
    add_index :event_seats, [:event_seating_configuration_id, :venue_seat_id], unique: true,
      name: "index_event_seats_on_configuration_and_venue_seat"
    add_index :event_seats, [:event_seating_configuration_id, :ticket_type_id]
    add_check_constraint :event_seats, "operational_status IN (0, 1, 2)", name: "event_seats_status_valid"

    create_table :seat_hold_sessions do |t|
      t.references :event_seating_configuration, null: false, foreign_key: { on_delete: :restrict },
        index: { name: "index_seat_hold_sessions_on_configuration_id" }
      t.references :order, foreign_key: { on_delete: :restrict }, index: { unique: true }
      t.references :user, foreign_key: { on_delete: :nullify }
      t.string :token_digest, null: false
      t.integer :status, null: false, default: 0
      t.string :source, null: false, default: "online"
      t.boolean :accessibility_attested, null: false, default: false
      t.datetime :expires_at, null: false
      t.datetime :claimed_at
      t.datetime :consumed_at
      t.datetime :released_at
      t.timestamps
    end
    add_index :seat_hold_sessions, :token_digest, unique: true
    add_index :seat_hold_sessions, [:status, :expires_at]
    add_check_constraint :seat_hold_sessions, "status IN (0, 1, 2, 3, 4)",
      name: "seat_hold_sessions_status_valid"

    create_table :seat_holds do |t|
      t.references :seat_hold_session, null: false, foreign_key: { on_delete: :restrict }
      t.references :event_seat, null: false, foreign_key: { on_delete: :restrict }
      t.references :order_item, foreign_key: { on_delete: :restrict }
      t.references :pricing_tier, foreign_key: { on_delete: :restrict }
      t.integer :unit_price_cents, null: false
      t.integer :status, null: false, default: 0
      t.datetime :released_at
      t.string :release_reason
      t.timestamps
    end
    add_index :seat_holds, [:seat_hold_session_id, :event_seat_id], unique: true,
      name: "index_seat_holds_on_session_and_event_seat"
    add_index :seat_holds, :event_seat_id, unique: true, where: "status IN (0, 1)",
      name: "index_seat_holds_one_blocking_per_event_seat"
    add_check_constraint :seat_holds, "status IN (0, 1, 2, 3, 4)", name: "seat_holds_status_valid"
    add_check_constraint :seat_holds, "unit_price_cents >= 0", name: "seat_holds_price_nonnegative"

    add_reference :tickets, :event_seat, foreign_key: { on_delete: :restrict }
    add_index :tickets, :event_seat_id, unique: true, where: "event_seat_id IS NOT NULL AND status IN (0, 1, 3)",
      name: "index_tickets_one_active_per_event_seat"

    create_table :accessible_seat_releases do |t|
      t.references :event_seat, null: false, foreign_key: { on_delete: :restrict }, index: { unique: true }
      t.references :released_by_user, null: false, foreign_key: { to_table: :users, on_delete: :restrict }
      t.string :release_scope, null: false
      t.string :reason, null: false
      t.jsonb :evidence, null: false, default: {}
      t.datetime :released_at, null: false
      t.timestamps
    end

    create_table :seat_audit_events do |t|
      t.references :event, null: false, foreign_key: { on_delete: :restrict }
      t.references :event_seat, foreign_key: { on_delete: :restrict }
      t.references :seat_hold_session, foreign_key: { on_delete: :restrict }
      t.references :ticket, foreign_key: { on_delete: :restrict }
      t.references :actor_user, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :action, null: false
      t.jsonb :metadata, null: false, default: {}
      t.datetime :occurred_at, null: false
      t.timestamps
    end
    add_index :seat_audit_events, [:event_id, :occurred_at]

    add_column :events, :sales_suspended_at, :datetime
    add_column :events, :sales_suspension_reason, :string
  end
end
