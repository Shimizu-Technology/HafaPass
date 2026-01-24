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

ActiveRecord::Schema[8.1].define(version: 2026_01_24_052840) do
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
    t.string "short_description"
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
    t.index ["slug"], name: "index_events_on_slug", unique: true
    t.index ["starts_at"], name: "index_events_on_starts_at"
    t.index ["status"], name: "index_events_on_status"
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

  add_foreign_key "events", "organizer_profiles"
  add_foreign_key "organizer_profiles", "users"
end
