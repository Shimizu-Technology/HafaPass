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

ActiveRecord::Schema[8.1].define(version: 2026_07_20_220000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "admission_actions", force: :cascade do |t|
    t.string "action_uuid", null: false
    t.bigint "actor_user_id"
    t.jsonb "attendee_snapshot", default: {}, null: false
    t.datetime "created_at", null: false
    t.string "credential_hash"
    t.bigint "event_id", null: false
    t.integer "kind", null: false
    t.integer "manifest_version"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "occurred_at", null: false
    t.bigint "organization_id", null: false
    t.string "reason_code", null: false
    t.datetime "received_at", null: false
    t.integer "result", null: false
    t.bigint "reverses_action_id"
    t.bigint "scanner_device_id"
    t.integer "sequence"
    t.integer "source", null: false
    t.bigint "ticket_id"
    t.datetime "updated_at", null: false
    t.index ["action_uuid"], name: "index_admission_actions_on_action_uuid", unique: true
    t.index ["actor_user_id"], name: "index_admission_actions_on_actor_user_id"
    t.index ["event_id", "occurred_at"], name: "index_admission_actions_on_event_id_and_occurred_at"
    t.index ["event_id", "result"], name: "index_admission_actions_on_event_id_and_result"
    t.index ["event_id"], name: "index_admission_actions_on_event_id"
    t.index ["organization_id"], name: "index_admission_actions_on_organization_id"
    t.index ["reverses_action_id"], name: "idx_admission_single_reversal", unique: true, where: "(reverses_action_id IS NOT NULL)"
    t.index ["reverses_action_id"], name: "index_admission_actions_on_reverses_action_id"
    t.index ["scanner_device_id", "sequence"], name: "idx_admission_device_sequence", unique: true, where: "((scanner_device_id IS NOT NULL) AND (sequence IS NOT NULL))"
    t.index ["scanner_device_id"], name: "index_admission_actions_on_scanner_device_id"
    t.index ["ticket_id"], name: "index_admission_actions_on_ticket_id"
    t.check_constraint "kind = ANY (ARRAY[0, 1])", name: "admission_actions_kind_valid"
    t.check_constraint "manifest_version IS NULL OR manifest_version > 0", name: "admission_actions_manifest_version_positive"
    t.check_constraint "result = ANY (ARRAY[0, 1, 2])", name: "admission_actions_result_valid"
    t.check_constraint "sequence IS NULL OR sequence > 0", name: "admission_actions_sequence_positive"
    t.check_constraint "source = ANY (ARRAY[0, 1, 2])", name: "admission_actions_source_valid"
  end

  create_table "admission_manifests", force: :cascade do |t|
    t.string "algorithm", default: "PS256", null: false
    t.datetime "created_at", null: false
    t.string "digest", null: false
    t.bigint "event_id", null: false
    t.datetime "expires_at", null: false
    t.datetime "generated_at", null: false
    t.bigint "generated_by_user_id"
    t.string "key_id", null: false
    t.bigint "organization_id", null: false
    t.jsonb "payload", default: {}, null: false
    t.text "signature", null: false
    t.string "source_digest", null: false
    t.integer "ticket_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.integer "version", null: false
    t.index ["digest"], name: "index_admission_manifests_on_digest", unique: true
    t.index ["event_id", "source_digest"], name: "index_admission_manifests_on_event_id_and_source_digest"
    t.index ["event_id", "version"], name: "index_admission_manifests_on_event_id_and_version", unique: true
    t.index ["event_id"], name: "index_admission_manifests_on_event_id"
    t.index ["generated_by_user_id"], name: "index_admission_manifests_on_generated_by_user_id"
    t.index ["organization_id"], name: "index_admission_manifests_on_organization_id"
    t.check_constraint "ticket_count >= 0", name: "admission_manifests_ticket_count_nonnegative"
    t.check_constraint "version > 0", name: "admission_manifests_version_positive"
  end

  create_table "audit_logs", force: :cascade do |t|
    t.string "action", null: false
    t.bigint "actor_user_id"
    t.jsonb "after_data", default: {}, null: false
    t.bigint "auditable_id", null: false
    t.string "auditable_type", null: false
    t.jsonb "before_data", default: {}, null: false
    t.datetime "created_at", null: false
    t.inet "ip_address"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "occurred_at", null: false
    t.bigint "organization_id"
    t.string "request_id"
    t.datetime "updated_at", null: false
    t.index ["actor_user_id"], name: "index_audit_logs_on_actor_user_id"
    t.index ["auditable_type", "auditable_id", "occurred_at"], name: "idx_audit_logs_auditable_time"
    t.index ["organization_id", "occurred_at"], name: "index_audit_logs_on_organization_id_and_occurred_at"
    t.index ["organization_id"], name: "index_audit_logs_on_organization_id"
  end

  create_table "balance_adjustments", force: :cascade do |t|
    t.integer "amount_cents", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_user_id"
    t.string "currency", default: "usd", null: false
    t.bigint "dispute_id"
    t.datetime "effective_at", null: false
    t.bigint "event_id"
    t.string "kind", null: false
    t.bigint "order_id"
    t.bigint "organization_id", null: false
    t.text "reason", null: false
    t.bigint "reversal_of_id"
    t.bigint "reversed_by_user_id"
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_user_id"], name: "index_balance_adjustments_on_created_by_user_id"
    t.index ["dispute_id"], name: "index_balance_adjustments_on_dispute_id"
    t.index ["event_id"], name: "index_balance_adjustments_on_event_id"
    t.index ["order_id"], name: "index_balance_adjustments_on_order_id"
    t.index ["organization_id"], name: "index_balance_adjustments_on_organization_id"
    t.index ["reversal_of_id"], name: "idx_balance_adjustments_one_reversal", unique: true, where: "(reversal_of_id IS NOT NULL)"
    t.index ["reversal_of_id"], name: "index_balance_adjustments_on_reversal_of_id"
    t.index ["reversed_by_user_id"], name: "index_balance_adjustments_on_reversed_by_user_id"
    t.check_constraint "amount_cents <> 0", name: "balance_adjustments_amount_nonzero"
    t.check_constraint "char_length(currency::text) = 3", name: "balance_adjustments_currency_length"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2])", name: "balance_adjustments_status_valid"
  end

  create_table "card_present_accounts", force: :cascade do |t|
    t.integer "connection_mode", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "device_id"
    t.datetime "last_seen_at"
    t.string "merchant_id"
    t.bigint "organization_id", null: false
    t.string "pos_id"
    t.string "provider", default: "boh_clover", null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.jsonb "verification_evidence", default: {}, null: false
    t.datetime "verified_at"
    t.bigint "verified_by_user_id"
    t.index ["organization_id"], name: "index_card_present_accounts_on_organization_id", unique: true
    t.index ["provider", "merchant_id"], name: "idx_card_present_provider_merchant", unique: true, where: "(merchant_id IS NOT NULL)"
    t.index ["verified_by_user_id"], name: "index_card_present_accounts_on_verified_by_user_id"
    t.check_constraint "connection_mode = ANY (ARRAY[0, 1])", name: "card_present_accounts_connection_mode_valid"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2])", name: "card_present_accounts_status_valid"
  end

  create_table "card_present_payment_attempts", force: :cascade do |t|
    t.integer "amount_cents", null: false
    t.bigint "card_present_account_id", null: false
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.string "currency", default: "usd", null: false
    t.bigint "event_id", null: false
    t.string "external_payment_id", null: false
    t.string "failure_code"
    t.text "failure_message"
    t.string "idempotency_key", null: false
    t.datetime "initiated_at", null: false
    t.bigint "initiated_by_user_id", null: false
    t.bigint "order_id", null: false
    t.bigint "organization_id", null: false
    t.bigint "payment_id", null: false
    t.string "provider", null: false
    t.string "provider_payment_id"
    t.jsonb "provider_response", default: {}, null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["card_present_account_id"], name: "index_card_present_payment_attempts_on_card_present_account_id"
    t.index ["event_id", "status"], name: "index_card_present_payment_attempts_on_event_id_and_status"
    t.index ["event_id"], name: "index_card_present_payment_attempts_on_event_id"
    t.index ["external_payment_id"], name: "index_card_present_payment_attempts_on_external_payment_id", unique: true
    t.index ["idempotency_key"], name: "index_card_present_payment_attempts_on_idempotency_key", unique: true
    t.index ["initiated_by_user_id"], name: "index_card_present_payment_attempts_on_initiated_by_user_id"
    t.index ["order_id"], name: "index_card_present_payment_attempts_on_order_id"
    t.index ["organization_id"], name: "index_card_present_payment_attempts_on_organization_id"
    t.index ["payment_id"], name: "index_card_present_payment_attempts_on_payment_id"
    t.index ["provider", "provider_payment_id"], name: "idx_card_present_unique_provider_payment", unique: true, where: "(provider_payment_id IS NOT NULL)"
    t.check_constraint "amount_cents > 0", name: "card_present_attempts_amount_positive"
    t.check_constraint "char_length(currency::text) = 3", name: "card_present_attempts_currency_length"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2, 3])", name: "card_present_attempts_status_valid"
  end

  create_table "connected_accounts", force: :cascade do |t|
    t.jsonb "capabilities", default: {}, null: false
    t.boolean "charges_enabled", default: false, null: false
    t.string "country", default: "GU", null: false
    t.datetime "created_at", null: false
    t.string "currency", default: "usd", null: false
    t.boolean "details_submitted", default: false, null: false
    t.datetime "last_synced_at"
    t.bigint "organization_id", null: false
    t.boolean "payouts_enabled", default: false, null: false
    t.string "provider", null: false
    t.string "provider_account_id"
    t.jsonb "requirements_due", default: [], null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "provider"], name: "index_connected_accounts_on_organization_id_and_provider", unique: true
    t.index ["organization_id"], name: "index_connected_accounts_on_organization_id"
    t.index ["provider", "provider_account_id"], name: "idx_connected_accounts_unique_provider_id", unique: true, where: "(provider_account_id IS NOT NULL)"
    t.check_constraint "char_length(currency::text) = 3", name: "connected_accounts_currency_length"
    t.check_constraint "provider::text = ANY (ARRAY['paypal'::character varying, 'manual'::character varying, 'stripe'::character varying, 'legacy_manual'::character varying]::text[])", name: "connected_accounts_provider_valid"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2, 3, 4, 5])", name: "connected_accounts_status_valid"
  end

  create_table "disputes", force: :cascade do |t|
    t.integer "amount_cents", null: false
    t.datetime "closed_at"
    t.datetime "created_at", null: false
    t.string "currency", default: "usd", null: false
    t.datetime "opened_at", null: false
    t.bigint "order_id", null: false
    t.bigint "payment_id"
    t.string "provider", default: "stripe", null: false
    t.string "provider_dispute_id", null: false
    t.jsonb "provider_payload", default: {}, null: false
    t.string "reason"
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_disputes_on_order_id"
    t.index ["payment_id"], name: "index_disputes_on_payment_id"
    t.index ["provider", "provider_dispute_id"], name: "index_disputes_on_provider_and_provider_dispute_id", unique: true
    t.check_constraint "amount_cents >= 0", name: "disputes_amount_nonnegative"
    t.check_constraint "char_length(currency::text) = 3", name: "disputes_currency_length"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2])", name: "disputes_status_valid"
  end

  create_table "event_change_responses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "decision", null: false
    t.bigint "event_change_id", null: false
    t.bigint "order_id", null: false
    t.datetime "responded_at", null: false
    t.datetime "updated_at", null: false
    t.index ["event_change_id", "order_id"], name: "idx_event_change_responses_unique", unique: true
    t.index ["event_change_id"], name: "index_event_change_responses_on_event_change_id"
    t.index ["order_id"], name: "index_event_change_responses_on_order_id"
  end

  create_table "event_changes", force: :cascade do |t|
    t.bigint "actor_user_id"
    t.jsonb "after_data", default: {}, null: false
    t.jsonb "before_data", default: {}, null: false
    t.string "change_type", null: false
    t.datetime "created_at", null: false
    t.bigint "event_id", null: false
    t.datetime "occurred_at", null: false
    t.string "reason"
    t.datetime "updated_at", null: false
    t.index ["actor_user_id"], name: "index_event_changes_on_actor_user_id"
    t.index ["event_id", "occurred_at"], name: "index_event_changes_on_event_id_and_occurred_at"
    t.index ["event_id"], name: "index_event_changes_on_event_id"
  end

  create_table "event_staff_assignments", force: :cascade do |t|
    t.bigint "assigned_by_user_id"
    t.datetime "created_at", null: false
    t.bigint "event_id", null: false
    t.datetime "expires_at"
    t.bigint "organization_id", null: false
    t.integer "role", null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["assigned_by_user_id"], name: "index_event_staff_assignments_on_assigned_by_user_id"
    t.index ["event_id", "user_id", "role"], name: "idx_event_staff_assignments_unique_role", unique: true
    t.index ["event_id"], name: "index_event_staff_assignments_on_event_id"
    t.index ["organization_id"], name: "index_event_staff_assignments_on_organization_id"
    t.index ["user_id"], name: "index_event_staff_assignments_on_user_id"
    t.check_constraint "role = ANY (ARRAY[0, 1, 2])", name: "event_staff_assignments_role_valid"
    t.check_constraint "status = ANY (ARRAY[0, 1])", name: "event_staff_assignments_status_valid"
  end

  create_table "event_state_changes", force: :cascade do |t|
    t.string "action", null: false
    t.bigint "actor_user_id", null: false
    t.datetime "created_at", null: false
    t.bigint "event_id", null: false
    t.string "from_status", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "occurred_at", null: false
    t.text "reason"
    t.string "to_status", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_user_id"], name: "index_event_state_changes_on_actor_user_id"
    t.index ["event_id", "occurred_at"], name: "index_event_state_changes_on_event_id_and_occurred_at"
    t.index ["event_id"], name: "index_event_state_changes_on_event_id"
  end

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
    t.bigint "organization_id", null: false
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
    t.index ["organization_id"], name: "index_events_on_organization_id"
    t.index ["organizer_profile_id"], name: "index_events_on_organizer_profile_id"
    t.index ["recurrence_parent_id"], name: "index_events_on_recurrence_parent_id"
    t.index ["slug"], name: "index_events_on_slug", unique: true
    t.index ["starts_at"], name: "index_events_on_starts_at"
    t.index ["status"], name: "index_events_on_status"
    t.check_constraint "max_capacity IS NULL OR max_capacity > 0", name: "events_capacity_positive"
  end

  create_table "fee_components", force: :cascade do |t|
    t.integer "amount_cents", null: false
    t.datetime "created_at", null: false
    t.string "currency", default: "usd", null: false
    t.boolean "estimated", default: true, null: false
    t.string "kind", null: false
    t.jsonb "metadata", default: {}, null: false
    t.bigint "order_id", null: false
    t.bigint "order_item_id"
    t.string "provider_reference"
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_fee_components_on_order_id"
    t.index ["order_item_id"], name: "index_fee_components_on_order_item_id"
    t.check_constraint "amount_cents >= 0", name: "fee_components_amount_nonnegative"
    t.check_constraint "char_length(currency::text) = 3", name: "fee_components_currency_length"
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

  create_table "inventory_holds", force: :cascade do |t|
    t.datetime "consumed_at"
    t.datetime "created_at", null: false
    t.bigint "event_id", null: false
    t.datetime "expires_at", null: false
    t.bigint "order_id", null: false
    t.bigint "order_item_id", null: false
    t.bigint "pricing_tier_id"
    t.integer "quantity", null: false
    t.string "release_reason"
    t.datetime "released_at"
    t.integer "status", default: 0, null: false
    t.bigint "ticket_type_id", null: false
    t.datetime "updated_at", null: false
    t.index ["event_id"], name: "index_inventory_holds_on_event_id"
    t.index ["order_id"], name: "index_inventory_holds_on_order_id"
    t.index ["order_item_id"], name: "index_inventory_holds_on_order_item_id", unique: true
    t.index ["pricing_tier_id"], name: "index_inventory_holds_on_pricing_tier_id"
    t.index ["status", "expires_at"], name: "index_inventory_holds_on_status_and_expires_at"
    t.index ["ticket_type_id"], name: "index_inventory_holds_on_ticket_type_id"
    t.check_constraint "quantity > 0", name: "inventory_holds_quantity_positive"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2, 3])", name: "inventory_holds_status_valid"
  end

  create_table "message_deliveries", force: :cascade do |t|
    t.integer "attempts", default: 0, null: false
    t.datetime "bounced_at"
    t.string "channel", default: "email", null: false
    t.datetime "complained_at"
    t.datetime "created_at", null: false
    t.datetime "delivered_at"
    t.bigint "event_id"
    t.datetime "failed_at"
    t.string "idempotency_key", null: false
    t.text "last_error"
    t.datetime "last_event_at"
    t.jsonb "metadata", default: {}, null: false
    t.bigint "order_id"
    t.string "payload_digest"
    t.string "provider", default: "resend", null: false
    t.string "provider_id"
    t.string "recipient", null: false
    t.bigint "requested_by_id"
    t.datetime "sent_at"
    t.integer "status", default: 0, null: false
    t.datetime "suppressed_at"
    t.string "template", null: false
    t.bigint "ticket_id"
    t.datetime "updated_at", null: false
    t.index ["event_id"], name: "index_message_deliveries_on_event_id"
    t.index ["idempotency_key"], name: "index_message_deliveries_on_idempotency_key", unique: true
    t.index ["order_id", "created_at"], name: "index_message_deliveries_on_order_id_and_created_at"
    t.index ["order_id"], name: "index_message_deliveries_on_order_id"
    t.index ["provider_id"], name: "index_message_deliveries_on_provider_id"
    t.index ["requested_by_id"], name: "index_message_deliveries_on_requested_by_id"
    t.index ["status", "updated_at"], name: "index_message_deliveries_on_status_and_updated_at"
    t.index ["ticket_id"], name: "index_message_deliveries_on_ticket_id"
    t.check_constraint "attempts >= 0", name: "message_deliveries_attempts_nonnegative"
    t.check_constraint "order_id IS NOT NULL OR ticket_id IS NOT NULL OR event_id IS NOT NULL", name: "message_deliveries_subject_present"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2, 3, 4, 5, 6, 7])", name: "message_deliveries_status_valid"
  end

  create_table "message_provider_events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.bigint "message_delivery_id"
    t.datetime "occurred_at", null: false
    t.jsonb "payload", default: {}, null: false
    t.datetime "processed_at"
    t.text "processing_error"
    t.string "provider", default: "resend", null: false
    t.string "provider_event_id", null: false
    t.string "provider_message_id"
    t.datetime "received_at", null: false
    t.datetime "updated_at", null: false
    t.index ["message_delivery_id"], name: "index_message_provider_events_on_message_delivery_id"
    t.index ["provider", "provider_event_id"], name: "index_message_provider_events_on_provider_event", unique: true
    t.index ["provider_message_id", "occurred_at"], name: "idx_on_provider_message_id_occurred_at_71bff7dab0"
  end

  create_table "order_items", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "currency", default: "usd", null: false
    t.integer "discount_cents", default: 0, null: false
    t.integer "fee_cents", default: 0, null: false
    t.string "name", null: false
    t.bigint "order_id", null: false
    t.integer "organizer_proceeds_cents", null: false
    t.bigint "pricing_tier_id"
    t.integer "quantity", null: false
    t.integer "subtotal_cents", null: false
    t.integer "tax_cents", default: 0, null: false
    t.bigint "ticket_type_id"
    t.string "tier_name"
    t.integer "unit_price_cents", null: false
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_order_items_on_order_id"
    t.index ["pricing_tier_id"], name: "index_order_items_on_pricing_tier_id"
    t.index ["ticket_type_id"], name: "index_order_items_on_ticket_type_id"
    t.check_constraint "char_length(currency::text) = 3", name: "order_items_currency_length"
    t.check_constraint "discount_cents >= 0", name: "order_items_discount_nonnegative"
    t.check_constraint "fee_cents >= 0", name: "order_items_fee_nonnegative"
    t.check_constraint "organizer_proceeds_cents <= subtotal_cents", name: "order_items_proceeds_within_subtotal"
    t.check_constraint "organizer_proceeds_cents >= 0", name: "order_items_proceeds_nonnegative"
    t.check_constraint "quantity > 0", name: "order_items_quantity_positive"
    t.check_constraint "subtotal_cents >= 0", name: "order_items_subtotal_nonnegative"
    t.check_constraint "tax_cents >= 0", name: "order_items_tax_nonnegative"
    t.check_constraint "unit_price_cents >= 0", name: "order_items_unit_price_nonnegative"
  end

  create_table "orders", force: :cascade do |t|
    t.string "buyer_email"
    t.string "buyer_name"
    t.string "buyer_phone"
    t.datetime "buyer_terms_accepted_at"
    t.string "buyer_terms_digest"
    t.string "buyer_terms_version"
    t.datetime "cancelled_at"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.string "currency", default: "usd", null: false
    t.integer "discount_cents", default: 0, null: false
    t.bigint "event_id", null: false
    t.datetime "expired_at"
    t.datetime "expires_at"
    t.datetime "guest_access_expires_at"
    t.datetime "guest_access_revoked_at"
    t.integer "guest_access_version", default: 1, null: false
    t.string "payment_method"
    t.bigint "promo_code_id"
    t.string "reference", null: false
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
    t.index ["reference"], name: "index_orders_on_reference", unique: true
    t.index ["source"], name: "index_orders_on_source"
    t.index ["stripe_payment_intent_id"], name: "index_orders_on_unique_payment_intent", unique: true, where: "(stripe_payment_intent_id IS NOT NULL)"
    t.index ["user_id"], name: "index_orders_on_user_id"
    t.check_constraint "char_length(currency::text) = 3", name: "orders_currency_length"
    t.check_constraint "discount_cents <= (subtotal_cents + service_fee_cents)", name: "orders_discount_within_charge"
    t.check_constraint "discount_cents >= 0", name: "orders_discount_nonnegative"
    t.check_constraint "guest_access_version > 0", name: "orders_guest_access_version_positive"
    t.check_constraint "refund_amount_cents <= total_cents", name: "orders_refund_within_total"
    t.check_constraint "refund_amount_cents >= 0", name: "orders_refund_nonnegative"
    t.check_constraint "service_fee_cents >= 0", name: "orders_service_fee_nonnegative"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2, 3, 4, 5])", name: "orders_status_valid"
    t.check_constraint "subtotal_cents >= 0", name: "orders_subtotal_nonnegative"
    t.check_constraint "total_cents = GREATEST(subtotal_cents + service_fee_cents - discount_cents, 0)", name: "orders_total_matches_components"
    t.check_constraint "total_cents >= 0", name: "orders_total_nonnegative"
  end

  create_table "organization_memberships", force: :cascade do |t|
    t.datetime "accepted_at"
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.integer "invitation_version", default: 1, null: false
    t.datetime "invited_at"
    t.bigint "invited_by_user_id"
    t.string "invited_email"
    t.bigint "organization_id", null: false
    t.integer "role", null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index "organization_id, lower((invited_email)::text)", name: "idx_organization_memberships_unique_invite", unique: true, where: "((invited_email IS NOT NULL) AND (status = 0))"
    t.index ["invited_by_user_id"], name: "index_organization_memberships_on_invited_by_user_id"
    t.index ["organization_id", "user_id"], name: "idx_organization_memberships_unique_user", unique: true, where: "(user_id IS NOT NULL)"
    t.index ["organization_id"], name: "index_organization_memberships_on_organization_id"
    t.index ["user_id"], name: "index_organization_memberships_on_user_id"
    t.check_constraint "invitation_version > 0", name: "organization_memberships_invitation_version_positive"
    t.check_constraint "role = ANY (ARRAY[0, 1, 2, 3, 4, 5])", name: "organization_memberships_role_valid"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2])", name: "organization_memberships_status_valid"
    t.check_constraint "user_id IS NOT NULL OR invited_email IS NOT NULL", name: "organization_memberships_identity_present"
  end

  create_table "organizations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "currency", default: "usd", null: false
    t.string "name", null: false
    t.string "slug", null: false
    t.integer "status", default: 0, null: false
    t.string "timezone", default: "Pacific/Guam", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_organizations_on_slug", unique: true
    t.check_constraint "char_length(currency::text) = 3", name: "organizations_currency_length"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2])", name: "organizations_status_valid"
  end

  create_table "organizer_profiles", force: :cascade do |t|
    t.text "business_description"
    t.string "business_name"
    t.datetime "created_at", null: false
    t.boolean "is_ambros_partner", default: false
    t.string "logo_url"
    t.bigint "organization_id", null: false
    t.boolean "payout_ready", default: false, null: false
    t.datetime "policy_accepted_at"
    t.string "policy_digest"
    t.string "policy_version"
    t.string "stripe_account_id"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.text "verification_notes"
    t.datetime "verification_requested_at"
    t.integer "verification_status", default: 0, null: false
    t.datetime "verified_at"
    t.bigint "verified_by_user_id"
    t.index ["organization_id"], name: "index_organizer_profiles_on_organization_id", unique: true
    t.index ["user_id"], name: "index_organizer_profiles_on_user_id", unique: true
    t.index ["verification_status"], name: "index_organizer_profiles_on_verification_status"
    t.index ["verified_by_user_id"], name: "index_organizer_profiles_on_verified_by_user_id"
  end

  create_table "payment_events", force: :cascade do |t|
    t.integer "amount_cents"
    t.datetime "created_at", null: false
    t.string "currency"
    t.jsonb "data", default: {}, null: false
    t.string "event_type", null: false
    t.bigint "payment_id"
    t.datetime "provider_created_at"
    t.datetime "updated_at", null: false
    t.bigint "webhook_event_id", null: false
    t.index ["payment_id"], name: "index_payment_events_on_payment_id"
    t.index ["webhook_event_id"], name: "index_payment_events_on_webhook_event_id", unique: true
    t.check_constraint "amount_cents IS NULL OR amount_cents >= 0", name: "payment_events_amount_nonnegative"
    t.check_constraint "currency IS NULL OR char_length(currency::text) = 3", name: "payment_events_currency_length"
  end

  create_table "payments", force: :cascade do |t|
    t.integer "amount_cents", null: false
    t.datetime "created_at", null: false
    t.string "currency", default: "usd", null: false
    t.datetime "failed_at"
    t.string "failure_code"
    t.text "failure_message"
    t.string "idempotency_key", null: false
    t.bigint "order_id", null: false
    t.string "provider", default: "stripe", null: false
    t.jsonb "provider_payload", default: {}, null: false
    t.string "provider_payment_id"
    t.integer "status", default: 0, null: false
    t.datetime "succeeded_at"
    t.datetime "updated_at", null: false
    t.index ["idempotency_key"], name: "index_payments_on_idempotency_key", unique: true
    t.index ["order_id"], name: "index_payments_on_order_id"
    t.index ["provider", "provider_payment_id"], name: "index_payments_on_unique_provider_payment", unique: true, where: "(provider_payment_id IS NOT NULL)"
    t.check_constraint "amount_cents >= 0", name: "payments_amount_nonnegative"
    t.check_constraint "char_length(currency::text) = 3", name: "payments_currency_length"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2, 3, 4, 5])", name: "payments_status_valid"
  end

  create_table "payouts", force: :cascade do |t|
    t.integer "amount_cents", null: false
    t.bigint "connected_account_id", null: false
    t.datetime "created_at", null: false
    t.string "currency", default: "usd", null: false
    t.bigint "event_id", null: false
    t.string "failure_code"
    t.text "failure_message"
    t.string "idempotency_key", null: false
    t.datetime "initiated_at"
    t.bigint "organization_id", null: false
    t.datetime "paid_at"
    t.string "provider", null: false
    t.string "provider_payout_id"
    t.bigint "settlement_id", null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["connected_account_id"], name: "index_payouts_on_connected_account_id"
    t.index ["event_id"], name: "index_payouts_on_event_id"
    t.index ["idempotency_key"], name: "index_payouts_on_idempotency_key", unique: true
    t.index ["organization_id"], name: "index_payouts_on_organization_id"
    t.index ["provider", "provider_payout_id"], name: "idx_payouts_unique_provider_id", unique: true, where: "(provider_payout_id IS NOT NULL)"
    t.index ["settlement_id"], name: "index_payouts_on_settlement_id"
    t.check_constraint "amount_cents > 0", name: "payouts_amount_positive"
    t.check_constraint "char_length(currency::text) = 3", name: "payouts_currency_length"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2, 3, 4])", name: "payouts_status_valid"
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
    t.check_constraint "price_cents >= 0", name: "pricing_tiers_price_nonnegative"
    t.check_constraint "quantity_sold >= 0", name: "pricing_tiers_sold_nonnegative"
    t.check_constraint "tier_type <> 1 OR quantity_sold <= quantity_limit", name: "pricing_tiers_sold_within_limit"
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
    t.check_constraint "current_uses >= 0", name: "promo_codes_uses_nonnegative"
    t.check_constraint "max_uses IS NULL OR max_uses > 0", name: "promo_codes_max_uses_positive"
  end

  create_table "promo_redemptions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "discount_cents", null: false
    t.datetime "expires_at"
    t.datetime "finalized_at"
    t.bigint "order_id", null: false
    t.bigint "promo_code_id", null: false
    t.datetime "released_at"
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_promo_redemptions_on_order_id", unique: true
    t.index ["promo_code_id", "status"], name: "index_promo_redemptions_on_promo_code_id_and_status"
    t.index ["promo_code_id"], name: "index_promo_redemptions_on_promo_code_id"
    t.check_constraint "discount_cents >= 0", name: "promo_redemptions_discount_nonnegative"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2])", name: "promo_redemptions_status_valid"
  end

  create_table "reconciliation_exceptions", force: :cascade do |t|
    t.integer "actual_amount_cents"
    t.string "actual_currency"
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.jsonb "details", default: {}, null: false
    t.integer "expected_amount_cents"
    t.string "expected_currency"
    t.bigint "order_id"
    t.bigint "payment_id"
    t.datetime "resolved_at"
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.bigint "webhook_event_id"
    t.index ["order_id"], name: "index_reconciliation_exceptions_on_order_id"
    t.index ["payment_id"], name: "index_reconciliation_exceptions_on_payment_id"
    t.index ["status", "created_at"], name: "index_reconciliation_exceptions_on_status_and_created_at"
    t.index ["webhook_event_id"], name: "index_reconciliation_exceptions_on_webhook_event_id"
    t.check_constraint "status = ANY (ARRAY[0, 1])", name: "reconciliation_exceptions_status_valid"
  end

  create_table "refund_items", force: :cascade do |t|
    t.integer "amount_cents", null: false
    t.datetime "created_at", null: false
    t.integer "fee_cents", default: 0, null: false
    t.bigint "order_item_id", null: false
    t.integer "organizer_proceeds_cents", default: 0, null: false
    t.integer "quantity", default: 0, null: false
    t.bigint "refund_id", null: false
    t.integer "tax_cents", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["order_item_id"], name: "index_refund_items_on_order_item_id"
    t.index ["refund_id", "order_item_id"], name: "index_refund_items_on_refund_id_and_order_item_id", unique: true
    t.index ["refund_id"], name: "index_refund_items_on_refund_id"
    t.check_constraint "amount_cents = (organizer_proceeds_cents + fee_cents + tax_cents)", name: "refund_items_components_match_amount"
    t.check_constraint "amount_cents >= 0", name: "refund_items_amount_nonnegative"
    t.check_constraint "fee_cents >= 0", name: "refund_items_fee_nonnegative"
    t.check_constraint "organizer_proceeds_cents >= 0", name: "refund_items_proceeds_nonnegative"
    t.check_constraint "quantity >= 0", name: "refund_items_quantity_nonnegative"
    t.check_constraint "tax_cents >= 0", name: "refund_items_tax_nonnegative"
  end

  create_table "refund_tickets", force: :cascade do |t|
    t.integer "amount_cents", null: false
    t.datetime "created_at", null: false
    t.bigint "refund_id", null: false
    t.bigint "ticket_id", null: false
    t.datetime "updated_at", null: false
    t.index ["refund_id"], name: "index_refund_tickets_on_refund_id"
    t.index ["ticket_id"], name: "index_refund_tickets_on_ticket_id", unique: true
    t.check_constraint "amount_cents >= 0", name: "refund_tickets_amount_nonnegative"
  end

  create_table "refunds", force: :cascade do |t|
    t.integer "amount_cents", null: false
    t.datetime "created_at", null: false
    t.string "currency", default: "usd", null: false
    t.datetime "failed_at"
    t.string "failure_code"
    t.text "failure_message"
    t.string "idempotency_key", null: false
    t.bigint "order_id", null: false
    t.bigint "payment_id"
    t.string "provider", default: "stripe", null: false
    t.jsonb "provider_payload", default: {}, null: false
    t.string "provider_refund_id"
    t.string "reason"
    t.bigint "requested_by_id"
    t.integer "status", default: 0, null: false
    t.datetime "succeeded_at"
    t.datetime "updated_at", null: false
    t.index ["idempotency_key"], name: "index_refunds_on_idempotency_key", unique: true
    t.index ["order_id"], name: "index_refunds_on_order_id"
    t.index ["payment_id"], name: "index_refunds_on_payment_id"
    t.index ["provider", "provider_refund_id"], name: "index_refunds_on_unique_provider_refund", unique: true, where: "(provider_refund_id IS NOT NULL)"
    t.index ["requested_by_id"], name: "index_refunds_on_requested_by_id"
    t.check_constraint "amount_cents > 0", name: "refunds_amount_positive"
    t.check_constraint "char_length(currency::text) = 3", name: "refunds_currency_length"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2, 3])", name: "refunds_status_valid"
  end

  create_table "scanner_devices", force: :cascade do |t|
    t.datetime "authorization_expires_at", null: false
    t.datetime "created_at", null: false
    t.bigint "event_id", null: false
    t.string "identifier", null: false
    t.string "last_manifest_digest"
    t.integer "last_manifest_version", default: 0, null: false
    t.datetime "last_seen_at"
    t.integer "last_sequence", default: 0, null: false
    t.datetime "last_synced_at"
    t.datetime "manifest_downloaded_at"
    t.jsonb "metadata", default: {}, null: false
    t.string "name", null: false
    t.bigint "organization_id", null: false
    t.datetime "revoked_at"
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["event_id", "identifier"], name: "index_scanner_devices_on_event_id_and_identifier", unique: true
    t.index ["event_id", "status"], name: "index_scanner_devices_on_event_id_and_status"
    t.index ["event_id"], name: "index_scanner_devices_on_event_id"
    t.index ["organization_id"], name: "index_scanner_devices_on_organization_id"
    t.index ["user_id"], name: "index_scanner_devices_on_user_id"
    t.check_constraint "last_manifest_version >= 0", name: "scanner_devices_manifest_version_nonnegative"
    t.check_constraint "last_sequence >= 0", name: "scanner_devices_sequence_nonnegative"
    t.check_constraint "status = ANY (ARRAY[0, 1])", name: "scanner_devices_status_valid"
  end

  create_table "settlement_items", force: :cascade do |t|
    t.integer "amount_cents", null: false
    t.datetime "created_at", null: false
    t.string "currency", default: "usd", null: false
    t.string "description", null: false
    t.string "kind", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "occurred_at", null: false
    t.bigint "settlement_id", null: false
    t.bigint "source_id"
    t.string "source_type"
    t.datetime "updated_at", null: false
    t.index ["settlement_id", "kind", "source_type", "source_id"], name: "idx_settlement_items_unique_source", unique: true, where: "(source_id IS NOT NULL)"
    t.index ["settlement_id"], name: "index_settlement_items_on_settlement_id"
    t.index ["source_type", "source_id"], name: "index_settlement_items_on_source_type_and_source_id"
    t.check_constraint "char_length(currency::text) = 3", name: "settlement_items_currency_length"
  end

  create_table "settlements", force: :cascade do |t|
    t.integer "adjustment_cents", default: 0, null: false
    t.datetime "calculated_at", null: false
    t.datetime "created_at", null: false
    t.string "currency", default: "usd", null: false
    t.integer "discount_cents", default: 0, null: false
    t.bigint "event_id", null: false
    t.datetime "finalized_at"
    t.integer "gross_cents", default: 0, null: false
    t.integer "negative_balance_cents", default: 0, null: false
    t.integer "net_cents", default: 0, null: false
    t.bigint "organization_id", null: false
    t.integer "organizer_proceeds_cents", default: 0, null: false
    t.integer "paid_cents", default: 0, null: false
    t.integer "payable_cents", default: 0, null: false
    t.integer "platform_fee_cents", default: 0, null: false
    t.integer "processing_fee_cents", default: 0, null: false
    t.integer "refund_cents", default: 0, null: false
    t.integer "reserve_cents", default: 0, null: false
    t.string "source_digest", null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.integer "version", null: false
    t.index ["event_id", "source_digest"], name: "index_settlements_on_event_id_and_source_digest", unique: true
    t.index ["event_id", "version"], name: "index_settlements_on_event_id_and_version", unique: true
    t.index ["event_id"], name: "index_settlements_on_event_id"
    t.index ["organization_id"], name: "index_settlements_on_organization_id"
    t.check_constraint "char_length(currency::text) = 3", name: "settlements_currency_length"
    t.check_constraint "discount_cents >= 0", name: "settlements_discount_nonnegative"
    t.check_constraint "gross_cents >= 0", name: "settlements_gross_nonnegative"
    t.check_constraint "negative_balance_cents >= 0", name: "settlements_negative_balance_nonnegative"
    t.check_constraint "net_cents >= 0", name: "settlements_net_nonnegative"
    t.check_constraint "organizer_proceeds_cents >= 0", name: "settlements_organizer_proceeds_nonnegative"
    t.check_constraint "paid_cents >= 0", name: "settlements_paid_nonnegative"
    t.check_constraint "payable_cents >= 0", name: "settlements_payable_nonnegative"
    t.check_constraint "platform_fee_cents >= 0", name: "settlements_platform_fee_nonnegative"
    t.check_constraint "processing_fee_cents >= 0", name: "settlements_processing_fee_nonnegative"
    t.check_constraint "refund_cents >= 0", name: "settlements_refund_nonnegative"
    t.check_constraint "reserve_cents >= 0", name: "settlements_reserve_nonnegative"
    t.check_constraint "status = ANY (ARRAY[0, 1])", name: "settlements_status_valid"
    t.check_constraint "version > 0", name: "settlements_version_positive"
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

  create_table "support_notes", force: :cascade do |t|
    t.bigint "author_user_id", null: false
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.bigint "event_id"
    t.bigint "order_id"
    t.bigint "ticket_id"
    t.datetime "updated_at", null: false
    t.index ["author_user_id"], name: "index_support_notes_on_author_user_id"
    t.index ["event_id", "created_at"], name: "index_support_notes_on_event_id_and_created_at"
    t.index ["event_id"], name: "index_support_notes_on_event_id"
    t.index ["order_id", "created_at"], name: "index_support_notes_on_order_id_and_created_at"
    t.index ["order_id"], name: "index_support_notes_on_order_id"
    t.index ["ticket_id", "created_at"], name: "index_support_notes_on_ticket_id_and_created_at"
    t.index ["ticket_id"], name: "index_support_notes_on_ticket_id"
    t.check_constraint "order_id IS NOT NULL OR ticket_id IS NOT NULL OR event_id IS NOT NULL", name: "support_notes_subject_present"
  end

  create_table "ticket_types", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.integer "door_allocation"
    t.bigint "event_id", null: false
    t.integer "max_per_buyer"
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
    t.check_constraint "door_allocation IS NULL OR door_allocation >= 0", name: "ticket_types_door_allocation_nonnegative"
    t.check_constraint "max_per_buyer IS NULL OR max_per_buyer > 0", name: "ticket_types_max_per_buyer_positive"
    t.check_constraint "max_per_order IS NULL OR max_per_order > 0", name: "ticket_types_max_per_order_positive"
    t.check_constraint "price_cents >= 0", name: "ticket_types_price_nonnegative"
    t.check_constraint "quantity_available > 0", name: "ticket_types_quantity_positive"
    t.check_constraint "quantity_sold <= quantity_available", name: "ticket_types_sold_within_capacity"
    t.check_constraint "quantity_sold >= 0", name: "ticket_types_sold_nonnegative"
  end

  create_table "tickets", force: :cascade do |t|
    t.string "attendee_email"
    t.string "attendee_name"
    t.string "cancellation_reason"
    t.datetime "cancelled_at"
    t.datetime "checked_in_at"
    t.datetime "created_at", null: false
    t.integer "display_credential_version", default: 1, null: false
    t.bigint "event_id", null: false
    t.bigint "order_id", null: false
    t.bigint "order_item_id"
    t.bigint "pricing_tier_id"
    t.string "qr_code"
    t.integer "scan_credential_version", default: 1, null: false
    t.integer "status", default: 0, null: false
    t.bigint "ticket_type_id", null: false
    t.datetime "updated_at", null: false
    t.index ["event_id"], name: "index_tickets_on_event_id"
    t.index ["order_id"], name: "index_tickets_on_order_id"
    t.index ["order_item_id"], name: "index_tickets_on_order_item_id"
    t.index ["pricing_tier_id"], name: "index_tickets_on_pricing_tier_id"
    t.index ["qr_code"], name: "index_tickets_on_qr_code", unique: true
    t.index ["ticket_type_id"], name: "index_tickets_on_ticket_type_id"
    t.check_constraint "display_credential_version > 0", name: "tickets_display_version_positive"
    t.check_constraint "scan_credential_version > 0", name: "tickets_scan_version_positive"
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

  create_table "webhook_events", force: :cascade do |t|
    t.integer "attempts", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.text "last_error"
    t.jsonb "payload", default: {}, null: false
    t.datetime "processed_at"
    t.string "provider", default: "stripe", null: false
    t.datetime "provider_created_at"
    t.string "provider_event_id", null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["provider", "provider_event_id"], name: "index_webhook_events_on_unique_provider_event", unique: true
    t.index ["status", "created_at"], name: "index_webhook_events_on_status_and_created_at"
    t.check_constraint "attempts >= 0", name: "webhook_events_attempts_nonnegative"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2, 3, 4])", name: "webhook_events_status_valid"
  end

  add_foreign_key "admission_actions", "admission_actions", column: "reverses_action_id", on_delete: :restrict
  add_foreign_key "admission_actions", "events", on_delete: :restrict
  add_foreign_key "admission_actions", "organizations", on_delete: :restrict
  add_foreign_key "admission_actions", "scanner_devices", on_delete: :restrict
  add_foreign_key "admission_actions", "tickets", on_delete: :restrict
  add_foreign_key "admission_actions", "users", column: "actor_user_id", on_delete: :restrict
  add_foreign_key "admission_manifests", "events", on_delete: :restrict
  add_foreign_key "admission_manifests", "organizations", on_delete: :restrict
  add_foreign_key "admission_manifests", "users", column: "generated_by_user_id", on_delete: :restrict
  add_foreign_key "audit_logs", "organizations", on_delete: :restrict
  add_foreign_key "audit_logs", "users", column: "actor_user_id", on_delete: :nullify
  add_foreign_key "balance_adjustments", "balance_adjustments", column: "reversal_of_id", on_delete: :restrict
  add_foreign_key "balance_adjustments", "disputes", on_delete: :restrict
  add_foreign_key "balance_adjustments", "events", on_delete: :restrict
  add_foreign_key "balance_adjustments", "orders", on_delete: :restrict
  add_foreign_key "balance_adjustments", "organizations", on_delete: :restrict
  add_foreign_key "balance_adjustments", "users", column: "created_by_user_id", on_delete: :nullify
  add_foreign_key "balance_adjustments", "users", column: "reversed_by_user_id", on_delete: :nullify
  add_foreign_key "card_present_accounts", "organizations", on_delete: :restrict
  add_foreign_key "card_present_accounts", "users", column: "verified_by_user_id", on_delete: :restrict
  add_foreign_key "card_present_payment_attempts", "card_present_accounts", on_delete: :restrict
  add_foreign_key "card_present_payment_attempts", "events", on_delete: :restrict
  add_foreign_key "card_present_payment_attempts", "orders", on_delete: :restrict
  add_foreign_key "card_present_payment_attempts", "organizations", on_delete: :restrict
  add_foreign_key "card_present_payment_attempts", "payments", on_delete: :restrict
  add_foreign_key "card_present_payment_attempts", "users", column: "initiated_by_user_id", on_delete: :restrict
  add_foreign_key "connected_accounts", "organizations", on_delete: :restrict
  add_foreign_key "disputes", "orders", on_delete: :restrict
  add_foreign_key "disputes", "payments", on_delete: :restrict
  add_foreign_key "event_change_responses", "event_changes", on_delete: :restrict
  add_foreign_key "event_change_responses", "orders", on_delete: :restrict
  add_foreign_key "event_changes", "events", on_delete: :restrict
  add_foreign_key "event_changes", "users", column: "actor_user_id", on_delete: :nullify
  add_foreign_key "event_staff_assignments", "events", on_delete: :restrict
  add_foreign_key "event_staff_assignments", "organizations", on_delete: :restrict
  add_foreign_key "event_staff_assignments", "users", column: "assigned_by_user_id", on_delete: :nullify
  add_foreign_key "event_staff_assignments", "users", on_delete: :restrict
  add_foreign_key "event_state_changes", "events"
  add_foreign_key "event_state_changes", "users", column: "actor_user_id"
  add_foreign_key "events", "organizations", on_delete: :restrict
  add_foreign_key "events", "organizer_profiles"
  add_foreign_key "fee_components", "order_items", on_delete: :restrict
  add_foreign_key "fee_components", "orders", on_delete: :restrict
  add_foreign_key "guest_list_entries", "events"
  add_foreign_key "guest_list_entries", "orders"
  add_foreign_key "guest_list_entries", "ticket_types"
  add_foreign_key "inventory_holds", "events", on_delete: :restrict
  add_foreign_key "inventory_holds", "order_items", on_delete: :restrict
  add_foreign_key "inventory_holds", "orders", on_delete: :restrict
  add_foreign_key "inventory_holds", "pricing_tiers", on_delete: :restrict
  add_foreign_key "inventory_holds", "ticket_types", on_delete: :restrict
  add_foreign_key "message_deliveries", "events", on_delete: :restrict
  add_foreign_key "message_deliveries", "orders", on_delete: :restrict
  add_foreign_key "message_deliveries", "tickets", on_delete: :restrict
  add_foreign_key "message_deliveries", "users", column: "requested_by_id", on_delete: :nullify
  add_foreign_key "message_provider_events", "message_deliveries", on_delete: :nullify
  add_foreign_key "order_items", "orders", on_delete: :restrict
  add_foreign_key "order_items", "pricing_tiers", on_delete: :restrict
  add_foreign_key "order_items", "ticket_types", on_delete: :restrict
  add_foreign_key "orders", "events"
  add_foreign_key "orders", "promo_codes"
  add_foreign_key "orders", "users"
  add_foreign_key "organization_memberships", "organizations", on_delete: :restrict
  add_foreign_key "organization_memberships", "users", column: "invited_by_user_id", on_delete: :nullify
  add_foreign_key "organization_memberships", "users", on_delete: :restrict
  add_foreign_key "organizer_profiles", "organizations", on_delete: :restrict
  add_foreign_key "organizer_profiles", "users"
  add_foreign_key "organizer_profiles", "users", column: "verified_by_user_id"
  add_foreign_key "payment_events", "payments", on_delete: :restrict
  add_foreign_key "payment_events", "webhook_events", on_delete: :restrict
  add_foreign_key "payments", "orders", on_delete: :restrict
  add_foreign_key "payouts", "connected_accounts", on_delete: :restrict
  add_foreign_key "payouts", "events", on_delete: :restrict
  add_foreign_key "payouts", "organizations", on_delete: :restrict
  add_foreign_key "payouts", "settlements", on_delete: :restrict
  add_foreign_key "pricing_tiers", "ticket_types"
  add_foreign_key "promo_codes", "events"
  add_foreign_key "promo_redemptions", "orders", on_delete: :restrict
  add_foreign_key "promo_redemptions", "promo_codes", on_delete: :restrict
  add_foreign_key "reconciliation_exceptions", "orders", on_delete: :restrict
  add_foreign_key "reconciliation_exceptions", "payments", on_delete: :restrict
  add_foreign_key "reconciliation_exceptions", "webhook_events", on_delete: :restrict
  add_foreign_key "refund_items", "order_items", on_delete: :restrict
  add_foreign_key "refund_items", "refunds", on_delete: :restrict
  add_foreign_key "refund_tickets", "refunds", on_delete: :restrict
  add_foreign_key "refund_tickets", "tickets", on_delete: :restrict
  add_foreign_key "refunds", "orders", on_delete: :restrict
  add_foreign_key "refunds", "payments", on_delete: :restrict
  add_foreign_key "refunds", "users", column: "requested_by_id", on_delete: :nullify
  add_foreign_key "scanner_devices", "events", on_delete: :restrict
  add_foreign_key "scanner_devices", "organizations", on_delete: :restrict
  add_foreign_key "scanner_devices", "users", on_delete: :restrict
  add_foreign_key "settlement_items", "settlements", on_delete: :restrict
  add_foreign_key "settlements", "events", on_delete: :restrict
  add_foreign_key "settlements", "organizations", on_delete: :restrict
  add_foreign_key "support_notes", "events", on_delete: :restrict
  add_foreign_key "support_notes", "orders", on_delete: :restrict
  add_foreign_key "support_notes", "tickets", on_delete: :restrict
  add_foreign_key "support_notes", "users", column: "author_user_id", on_delete: :restrict
  add_foreign_key "ticket_types", "events"
  add_foreign_key "tickets", "events"
  add_foreign_key "tickets", "order_items", on_delete: :restrict
  add_foreign_key "tickets", "orders"
  add_foreign_key "tickets", "pricing_tiers"
  add_foreign_key "tickets", "ticket_types"
  add_foreign_key "waitlist_entries", "events"
  add_foreign_key "waitlist_entries", "ticket_types"
  add_foreign_key "waitlist_entries", "users"
end
