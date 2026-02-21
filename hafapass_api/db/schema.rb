# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_02_21_103243) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "events", force: :cascade do |t|
    t.integer "age_restriction", default: 0
    t.integer "category", default: 5
    t.string "cover_image_url"
    t.datetime "created_at", null: false
    t.text "description"
    t.datetime "doors_open_at"
    t.datetime "ends_at"
    t.boolean "is_featured", default: false
    t.integer "max_capacity"
    t.bigint "organizer_profile_id", null: false
    t.datetime "published_at"
    t.date "recurrence_end_date"
    t.integer "recurrence_parent_id"
    t.string "recurrence_rule"
    t.string "short_description"
    t.boolean "show_attendees", default: true
    t.string "slug", null: false
    t.datetime "starts_at"
    t.integer "status", default: 0
    t.string "timezone", default: "Pacific/Guam"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.string "venue_address"
    t.string "venue_city"
    t.string "venue_name"
    t.index ["organizer_profile_id"], name: "index_events_on_organizer_profile_id"
    t.index ["recurrence_parent_id"], name: "index_events_on_recurrence_parent_id"
    t.index ["slug"], name: "index_events_on_slug", unique: true
    t.index ["starts_at"], name: "index_events_on_starts_at"
    t.index ["status"], name: "index_events_on_status"
  end

  create_table "guest_list_entries", force: :cascade do |t|
    t.string "added_by"
    t.datetime "created_at", null: false
    t.bigint "event_id", null: false
    t.string "guest_email"
    t.string "guest_name", null: false
    t.string "guest_phone"
    t.string "notes"
    t.bigint "order_id"
    t.integer "quantity", default: 1, null: false
    t.boolean "redeemed", default: false, null: false
    t.bigint "ticket_type_id", null: false
    t.datetime "updated_at", null: false
    t.index ["event_id", "guest_email"], name: "index_guest_list_entries_on_event_id_and_guest_email"
    t.index ["event_id"], name: "index_guest_list_entries_on_event_id"
    t.index ["order_id"], name: "index_guest_list_entries_on_order_id"
    t.index ["ticket_type_id"], name: "index_guest_list_entries_on_ticket_type_id"
  end

  create_table "orders", force: :cascade do |t|
    t.string "buyer_email"
    t.string "buyer_name"
    t.string "buyer_phone"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.integer "discount_cents", default: 0, null: false
    t.bigint "event_id", null: false
    t.string "payment_method"
    t.bigint "promo_code_id"
    t.integer "refund_amount_cents", default: 0, null: false
    t.string "refund_reason"
    t.datetime "refunded_at"
    t.integer "service_fee_cents", default: 0, null: false
    t.string "source"
    t.integer "status", default: 0, null: false
    t.string "stripe_payment_intent_id"
    t.string "stripe_refund_id"
    t.integer "subtotal_cents", default: 0, null: false
    t.integer "total_cents", default: 0, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.string "wallet_type"
    t.index ["event_id"], name: "index_orders_on_event_id"
    t.index ["payment_method"], name: "index_orders_on_payment_method"
    t.index ["promo_code_id"], name: "index_orders_on_promo_code_id"
    t.index ["source"], name: "index_orders_on_source"
    t.index ["user_id"], name: "index_orders_on_user_id"
  end

  create_table "organizer_profiles", force: :cascade do |t|
    t.text "business_description"
    t.string "business_name"
    t.datetime "created_at", null: false
    t.boolean "is_ambros_partner", default: false
    t.string "logo_url"
    t.string "stripe_account_id"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_organizer_profiles_on_user_id"
  end

  create_table "pricing_tiers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "ends_at"
    t.string "name"
    t.integer "position", default: 0, null: false
    t.integer "price_cents"
    t.integer "quantity_limit"
    t.integer "quantity_sold", default: 0, null: false
    t.datetime "starts_at"
    t.bigint "ticket_type_id", null: false
    t.integer "tier_type"
    t.datetime "updated_at", null: false
    t.index ["ticket_type_id"], name: "index_pricing_tiers_on_ticket_type_id"
  end

  create_table "promo_codes", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.integer "current_uses", default: 0, null: false
    t.string "discount_type", default: "percentage", null: false
    t.integer "discount_value", null: false
    t.bigint "event_id", null: false
    t.datetime "expires_at"
    t.integer "max_uses"
    t.datetime "starts_at"
    t.datetime "updated_at", null: false
    t.index ["event_id", "code"], name: "index_promo_codes_on_event_id_and_code", unique: true
    t.index ["event_id"], name: "index_promo_codes_on_event_id"
  end

  create_table "site_settings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "payment_mode", default: "simulate", null: false
    t.string "platform_email", default: "tickets@hafapass.com"
    t.string "platform_name", default: "HafaPass"
    t.string "platform_phone"
    t.integer "service_fee_flat_cents", default: 50
    t.decimal "service_fee_percent", precision: 5, scale: 2, default: "3.0"
    t.integer "singleton_guard", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["singleton_guard"], name: "index_site_settings_on_singleton_guard", unique: true
  end

  create_table "ticket_types", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.bigint "event_id", null: false
    t.integer "max_per_order", default: 10
    t.string "name", null: false
    t.integer "price_cents"
    t.integer "quantity_available"
    t.integer "quantity_sold", default: 0, null: false
    t.datetime "sales_end_at"
    t.datetime "sales_start_at"
    t.integer "sort_order", default: 0
    t.datetime "updated_at", null: false
    t.index ["event_id"], name: "index_ticket_types_on_event_id"
  end

  create_table "tickets", force: :cascade do |t|
    t.string "attendee_email"
    t.string "attendee_name"
    t.datetime "checked_in_at"
    t.datetime "created_at", null: false
    t.bigint "event_id", null: false
    t.bigint "order_id", null: false
    t.string "qr_code"
    t.integer "status", default: 0, null: false
    t.bigint "ticket_type_id", null: false
    t.datetime "updated_at", null: false
    t.index ["event_id"], name: "index_tickets_on_event_id"
    t.index ["order_id"], name: "index_tickets_on_order_id"
    t.index ["qr_code"], name: "index_tickets_on_qr_code", unique: true
    t.index ["ticket_type_id"], name: "index_tickets_on_ticket_type_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "clerk_id", null: false
    t.datetime "created_at", null: false
    t.string "email"
    t.string "first_name"
    t.string "last_name"
    t.string "phone"
    t.integer "role", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["clerk_id"], name: "index_users_on_clerk_id", unique: true
  end

  create_table "waitlist_entries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.bigint "event_id", null: false
    t.datetime "expires_at"
    t.string "name"
    t.datetime "notified_at"
    t.string "phone"
    t.integer "position", null: false
    t.integer "quantity", default: 1, null: false
    t.integer "status", default: 0, null: false
    t.bigint "ticket_type_id"
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["event_id", "ticket_type_id", "email"], name: "idx_waitlist_unique_entry", unique: true
    t.index ["event_id", "ticket_type_id", "position"], name: "idx_on_event_id_ticket_type_id_position_e28bca8bda"
    t.index ["event_id"], name: "index_waitlist_entries_on_event_id"
    t.index ["ticket_type_id"], name: "index_waitlist_entries_on_ticket_type_id"
    t.index ["user_id"], name: "index_waitlist_entries_on_user_id"
  end

  add_foreign_key "events", "organizer_profiles"
  add_foreign_key "guest_list_entries", "events"
  add_foreign_key "guest_list_entries", "orders"
  add_foreign_key "guest_list_entries", "ticket_types"
  add_foreign_key "orders", "events"
  add_foreign_key "orders", "promo_codes"
  add_foreign_key "orders", "users"
  add_foreign_key "organizer_profiles", "users"
  add_foreign_key "pricing_tiers", "ticket_types"
  add_foreign_key "promo_codes", "events"
  add_foreign_key "ticket_types", "events"
  add_foreign_key "tickets", "events"
  add_foreign_key "tickets", "orders"
  add_foreign_key "tickets", "ticket_types"
  add_foreign_key "waitlist_entries", "events"
  add_foreign_key "waitlist_entries", "ticket_types"
  add_foreign_key "waitlist_entries", "users"
end
