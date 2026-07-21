# frozen_string_literal: true

class CreateMarketplaceGrowth < ActiveRecord::Migration[8.1]
  def change
    create_table :venues do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.string :address, null: false
      t.string :village, null: false
      t.text :description
      t.string :website_url
      t.text :accessibility_notes
      t.boolean :verified, null: false, default: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :venues, :slug, unique: true
    add_index :venues, [:active, :village, :name]

    add_reference :events, :venue, foreign_key: { on_delete: :restrict }
    add_index :events, [:status, :starts_at, :category], name: "index_events_discovery"
    add_index :events, "LOWER(venue_city)", name: "index_events_on_lower_venue_city"

    create_table :marketplace_collections do |t|
      t.references :created_by_user, null: false, foreign_key: { to_table: :users, on_delete: :restrict }
      t.string :title, null: false
      t.string :slug, null: false
      t.text :description
      t.integer :status, null: false, default: 0
      t.integer :position, null: false, default: 0
      t.datetime :starts_at
      t.datetime :ends_at
      t.string :seo_title
      t.string :seo_description
      t.timestamps
    end
    add_index :marketplace_collections, :slug, unique: true
    add_index :marketplace_collections, [:status, :position]
    add_check_constraint :marketplace_collections, "status IN (0, 1, 2)", name: "marketplace_collections_status_valid"
    add_check_constraint :marketplace_collections, "ends_at IS NULL OR starts_at IS NULL OR ends_at > starts_at",
      name: "marketplace_collections_dates_valid"

    create_table :marketplace_collection_events do |t|
      t.references :marketplace_collection, null: false, foreign_key: { on_delete: :cascade }
      t.references :event, null: false, foreign_key: { on_delete: :restrict }
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :marketplace_collection_events, [:marketplace_collection_id, :event_id], unique: true,
      name: "index_collection_events_unique"
    add_index :marketplace_collection_events, [:marketplace_collection_id, :position],
      name: "index_collection_events_position"

    create_table :event_favorites do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :event, null: false, foreign_key: { on_delete: :cascade }
      t.timestamps
    end
    add_index :event_favorites, [:user_id, :event_id], unique: true

    create_table :organizer_follows do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :organization, null: false, foreign_key: { on_delete: :cascade }
      t.timestamps
    end
    add_index :organizer_follows, [:user_id, :organization_id], unique: true

    create_table :event_reminders do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :event, null: false, foreign_key: { on_delete: :cascade }
      t.integer :status, null: false, default: 0
      t.datetime :remind_at, null: false
      t.datetime :sent_at
      t.timestamps
    end
    add_index :event_reminders, [:user_id, :event_id], unique: true
    add_index :event_reminders, [:status, :remind_at]
    add_check_constraint :event_reminders, "status IN (0, 1, 2)", name: "event_reminders_status_valid"

    create_table :distribution_partners do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.integer :kind, null: false
      t.string :website_url
      t.string :contact_name
      t.string :contact_email
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :distribution_partners, :slug, unique: true
    add_index :distribution_partners, [:active, :kind]
    add_check_constraint :distribution_partners, "kind IN (0, 1, 2, 3, 4)",
      name: "distribution_partners_kind_valid"

    create_table :distribution_links do |t|
      t.references :distribution_partner, null: false, foreign_key: { on_delete: :restrict }
      t.references :event, null: false, foreign_key: { on_delete: :restrict }
      t.references :created_by_user, null: false, foreign_key: { to_table: :users, on_delete: :restrict }
      t.string :code, null: false
      t.string :campaign, null: false
      t.boolean :active, null: false, default: true
      t.datetime :expires_at
      t.timestamps
    end
    add_index :distribution_links, :code, unique: true
    add_index :distribution_links, [:event_id, :active]
    add_index :distribution_links, [:distribution_partner_id, :active]

    create_table :marketplace_funnel_events do |t|
      t.references :event, null: false, foreign_key: { on_delete: :restrict }
      t.references :distribution_link, foreign_key: { on_delete: :restrict }
      t.references :order, foreign_key: { on_delete: :restrict }
      t.string :visitor_hash, null: false
      t.integer :stage, null: false
      t.string :source
      t.string :medium
      t.string :campaign
      t.datetime :occurred_at, null: false
      t.timestamps
    end
    add_check_constraint :marketplace_funnel_events, "stage IN (0, 1, 2, 3)",
      name: "marketplace_funnel_stage_valid"
    add_index :marketplace_funnel_events, [:event_id, :stage, :occurred_at], name: "index_funnel_event_stage_time"
    add_index :marketplace_funnel_events, [:visitor_hash, :occurred_at], name: "index_funnel_visitor_time"
    add_index :marketplace_funnel_events, [:order_id, :stage], unique: true, where: "order_id IS NOT NULL",
      name: "index_funnel_order_stage_unique"

    create_table :acquisition_attributions do |t|
      t.references :order, null: false, foreign_key: { on_delete: :restrict }, index: { unique: true }
      t.references :distribution_link, foreign_key: { on_delete: :restrict }
      t.string :visitor_hash, null: false
      t.string :source
      t.string :medium
      t.string :campaign
      t.datetime :attributed_at, null: false
      t.timestamps
    end
  end
end
