# frozen_string_literal: true

class CreateEventSeries < ActiveRecord::Migration[8.1]
  def change
    create_table :event_series do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :name, null: false
      t.string :slug, null: false
      t.text :description
      t.integer :status, null: false, default: 0
      t.integer :revenue_share_bps
      t.string :revenue_share_base, null: false, default: "admissions_net_proceeds"
      t.boolean :revenue_share_includes_door_cash, null: false, default: true
      t.string :revenue_share_label
      t.string :primary_share_label

      t.timestamps

      t.index [:organization_id, :slug], unique: true
      t.check_constraint "status = ANY (ARRAY[0, 1, 2, 3])", name: "chk_event_series_status"
      t.check_constraint "revenue_share_bps IS NULL OR (revenue_share_bps >= 0 AND revenue_share_bps <= 10000)",
        name: "chk_event_series_revenue_share_bps"
      t.check_constraint "revenue_share_base IN ('admissions_net_proceeds', 'admissions_gross', 'admissions_net_after_processing', 'all_net_proceeds')",
        name: "chk_event_series_revenue_share_base"
    end

    create_table :event_series_memberships do |t|
      t.references :event_series, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :event, null: false, foreign_key: { on_delete: :cascade }, index: true
      t.integer :role, null: false, default: 0
      t.integer :position, null: false, default: 0

      t.timestamps

      t.index [:event_series_id, :event_id], unique: true
      t.check_constraint "role = ANY (ARRAY[0, 1, 2, 3, 4])", name: "chk_event_series_memberships_role"
      t.check_constraint "position >= 0", name: "chk_event_series_memberships_position"
    end
  end
end
