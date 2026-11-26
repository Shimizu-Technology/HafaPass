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

ActiveRecord::Schema[8.1].define(version: 2026_11_26_180100) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "accessible_seat_releases", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "event_seat_id", null: false
    t.jsonb "evidence", default: {}, null: false
    t.string "reason", null: false
    t.string "release_scope", null: false
    t.datetime "released_at", null: false
    t.bigint "released_by_user_id", null: false
    t.datetime "updated_at", null: false
    t.index ["event_seat_id"], name: "index_accessible_seat_releases_on_event_seat_id", unique: true
    t.index ["released_by_user_id"], name: "index_accessible_seat_releases_on_released_by_user_id"
  end

  create_table "acquisition_attributions", force: :cascade do |t|
    t.datetime "attributed_at", null: false
    t.string "campaign"
    t.datetime "created_at", null: false
    t.bigint "distribution_link_id"
    t.bigint "event_referral_id"
    t.string "medium"
    t.bigint "order_id", null: false
    t.string "source"
    t.datetime "updated_at", null: false
    t.string "visitor_hash", null: false
    t.index ["distribution_link_id"], name: "index_acquisition_attributions_on_distribution_link_id"
    t.index ["event_referral_id"], name: "index_acquisition_attributions_on_event_referral_id"
    t.index ["order_id"], name: "index_acquisition_attributions_on_order_id", unique: true
  end

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
    t.datetime "retention_anonymized_at"
    t.date "occupancy_day"
    t.index ["action_uuid"], name: "index_admission_actions_on_action_uuid", unique: true
    t.index ["actor_user_id"], name: "index_admission_actions_on_actor_user_id"
    t.index ["event_id", "occupancy_day", "occurred_at"], name: "index_admission_actions_on_event_day_occurred_at"
    t.index ["event_id", "occurred_at"], name: "index_admission_actions_on_event_id_and_occurred_at"
    t.index ["event_id", "result"], name: "index_admission_actions_on_event_id_and_result"
    t.index ["event_id"], name: "index_admission_actions_on_event_id"
    t.index ["organization_id"], name: "index_admission_actions_on_organization_id"
    t.index ["retention_anonymized_at"], name: "index_admission_actions_on_retention_anonymized_at"
    t.index ["reverses_action_id"], name: "idx_admission_single_reversal", unique: true, where: "((reverses_action_id IS NOT NULL) AND (result = 0))"
    t.index ["reverses_action_id"], name: "index_admission_actions_on_reverses_action_id"
    t.index ["scanner_device_id", "sequence"], name: "idx_admission_device_sequence", unique: true, where: "((scanner_device_id IS NOT NULL) AND (sequence IS NOT NULL))"
    t.index ["scanner_device_id"], name: "index_admission_actions_on_scanner_device_id"
    t.index ["ticket_id"], name: "index_admission_actions_on_ticket_id"
    t.check_constraint "kind = ANY (ARRAY[0, 1, 2, 3])", name: "admission_actions_kind_valid_re_entry"
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
    t.datetime "retention_anonymized_at"
    t.index ["digest"], name: "index_admission_manifests_on_digest", unique: true
    t.index ["event_id", "source_digest"], name: "index_admission_manifests_on_event_id_and_source_digest"
    t.index ["event_id", "version"], name: "index_admission_manifests_on_event_id_and_version", unique: true
    t.index ["event_id"], name: "index_admission_manifests_on_event_id"
    t.index ["generated_by_user_id"], name: "index_admission_manifests_on_generated_by_user_id"
    t.index ["organization_id"], name: "index_admission_manifests_on_organization_id"
    t.index ["retention_anonymized_at"], name: "index_admission_manifests_on_retention_anonymized_at"
    t.check_constraint "ticket_count >= 0", name: "admission_manifests_ticket_count_nonnegative"
    t.check_constraint "version > 0", name: "admission_manifests_version_positive"
  end

  create_table "annual_tax_report_settings", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.integer "year", null: false
    t.string "form_type", default: "review_required", null: false
    t.string "jurisdiction", default: "irs", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "payee_key", default: "all", null: false
    t.index ["organization_id", "year", "payee_key"], name: "idx_annual_tax_settings_on_payee_year", unique: true
    t.index ["organization_id"], name: "index_annual_tax_report_settings_on_organization_id"
    t.check_constraint "form_type::text = ANY (ARRAY['review_required'::character varying::text, '1099-nec'::character varying::text, '1099-misc'::character varying::text, '1099-k'::character varying::text, 'none'::character varying::text])", name: "annual_tax_report_form_valid"
    t.check_constraint "jurisdiction::text = ANY (ARRAY['irs'::character varying::text, 'guam_drt'::character varying::text])", name: "annual_tax_report_jurisdiction_valid"
  end

  create_table "annual_tax_thresholds", force: :cascade do |t|
    t.integer "year", null: false
    t.string "form_type", null: false
    t.integer "amount_cents", null: false
    t.integer "transaction_count"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["year", "form_type"], name: "index_annual_tax_thresholds_on_year_and_form_type", unique: true
  end

  create_table "apple_wallet_registrations", force: :cascade do |t|
    t.bigint "wallet_pass_id", null: false
    t.string "device_library_identifier", null: false
    t.string "push_token", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["device_library_identifier", "wallet_pass_id"], name: "index_apple_wallet_registrations_on_device_and_pass", unique: true
    t.index ["wallet_pass_id"], name: "index_apple_wallet_registrations_on_wallet_pass_id"
  end

  create_table "audience_mailings", force: :cascade do |t|
    t.bigint "organization_id"
    t.bigint "created_by_id", null: false
    t.string "subject", null: false
    t.text "body", null: false
    t.string "audience", null: false
    t.string "status", default: "draft", null: false
    t.datetime "scheduled_at"
    t.bigint "cursor", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "recipient_emails", default: [], null: false
    t.jsonb "filters", default: {}, null: false
    t.integer "recipient_count", default: 0, null: false
    t.string "blocked_reason"
    t.index ["created_by_id"], name: "index_audience_mailings_on_created_by_id"
    t.index ["organization_id"], name: "index_audience_mailings_on_organization_id"
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
    t.datetime "retention_anonymized_at"
    t.bigint "event_id"
    t.string "source"
    t.string "outcome"
    t.string "deduplication_key"
    t.index ["action", "deduplication_key"], name: "idx_audit_logs_retry_key", unique: true, where: "(deduplication_key IS NOT NULL)"
    t.index ["actor_user_id"], name: "index_audit_logs_on_actor_user_id"
    t.index ["auditable_type", "auditable_id", "occurred_at"], name: "idx_audit_logs_auditable_time"
    t.index ["event_id", "occurred_at"], name: "index_audit_logs_on_event_id_and_occurred_at"
    t.index ["organization_id", "occurred_at"], name: "index_audit_logs_on_organization_id_and_occurred_at"
    t.index ["organization_id"], name: "index_audit_logs_on_organization_id"
    t.index ["retention_anonymized_at"], name: "index_audit_logs_on_retention_anonymized_at"
    t.check_constraint "outcome IS NULL OR (outcome::text = ANY (ARRAY['requested'::character varying::text, 'succeeded'::character varying::text, 'failed'::character varying::text, 'unknown'::character varying::text]))", name: "audit_logs_outcome"
    t.check_constraint "source IS NULL OR (source::text = ANY (ARRAY['user'::character varying::text, 'system'::character varying::text, 'provider'::character varying::text, 'admin'::character varying::text]))", name: "audit_logs_source"
  end

  create_table "audit_write_failures", force: :cascade do |t|
    t.string "action", null: false
    t.string "auditable_type", null: false
    t.bigint "auditable_id", null: false
    t.bigint "organization_id"
    t.bigint "event_id"
    t.bigint "actor_user_id"
    t.string "source", null: false
    t.string "failure_class", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
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
    t.date "reserve_release_on"
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

  create_table "buyer_return_postings", force: :cascade do |t|
    t.bigint "never_fulfilled_capture_id", null: false
    t.integer "sequence", null: false
    t.string "kind", null: false
    t.string "source_type", null: false
    t.bigint "source_id", null: false
    t.bigint "reverses_posting_id"
    t.integer "gross_cents", null: false
    t.integer "applied_cents", null: false
    t.integer "excess_cents", null: false
    t.integer "proceeds_cents", null: false
    t.integer "fee_cents", null: false
    t.integer "organizer_fee_cents", null: false
    t.integer "tax_cents", null: false
    t.datetime "recorded_at", null: false
    t.string "recording_source", null: false
    t.datetime "capture_recorded_at", null: false
    t.datetime "recognized_at", null: false
    t.string "recognition_state", default: "recognized", null: false
    t.string "allocation_policy", null: false
    t.string "policy_version", null: false
    t.string "allocation_method", null: false
    t.jsonb "evidence", default: {}, null: false
    t.text "note"
    t.datetime "posted_at", default: -> { "timezone('UTC'::text, clock_timestamp())" }, null: false
    t.index ["kind", "source_type", "source_id"], name: "index_buyer_return_postings_on_movement", unique: true
    t.index ["never_fulfilled_capture_id", "sequence"], name: "index_buyer_return_postings_on_capture_sequence", unique: true
    t.index ["recognized_at"], name: "index_buyer_return_postings_on_recognized_at"
    t.index ["reverses_posting_id"], name: "index_buyer_return_postings_on_reverses_posting_id", unique: true
    t.check_constraint "(applied_cents + excess_cents) = gross_cents", name: "buyer_return_postings_gross_identity"
    t.check_constraint "(kind::text = ANY (ARRAY['refund'::character varying::text, 'dispute_loss'::character varying::text])) AND reverses_posting_id IS NULL AND gross_cents > 0 AND applied_cents >= 0 AND excess_cents >= 0 AND proceeds_cents >= 0 AND fee_cents >= 0 AND organizer_fee_cents >= 0 AND tax_cents >= 0 OR (kind::text = ANY (ARRAY['dispute_loss_reversal'::character varying::text, 'refund_reversal'::character varying::text])) AND reverses_posting_id IS NOT NULL AND gross_cents < 0", name: "buyer_return_postings_direction"
    t.check_constraint "(kind::text = ANY (ARRAY['refund'::character varying::text, 'refund_reversal'::character varying::text])) AND source_type::text = 'Refund'::text OR (kind::text = ANY (ARRAY['dispute_loss'::character varying::text, 'dispute_loss_reversal'::character varying::text])) AND source_type::text = 'Dispute'::text", name: "buyer_return_postings_source_matches_kind"
    t.check_constraint "(proceeds_cents + fee_cents + organizer_fee_cents + tax_cents) = applied_cents", name: "buyer_return_postings_components_sum"
    t.check_constraint "allocation_method::text = ANY (ARRAY['refund_items'::character varying::text, 'bounded'::character varying::text, 'cumulative_pro_rata'::character varying::text, 'recomputed'::character varying::text])", name: "buyer_return_postings_allocation_method_valid"
    t.check_constraint "kind::text = ANY (ARRAY['refund'::character varying::text, 'dispute_loss'::character varying::text, 'dispute_loss_reversal'::character varying::text, 'refund_reversal'::character varying::text])", name: "buyer_return_postings_kind_valid"
    t.check_constraint "recognition_state::text = ANY (ARRAY['recognized'::character varying::text, 'pending_correction'::character varying::text])", name: "buyer_return_postings_recognition_state_valid"
    t.check_constraint "recognized_at = GREATEST(recorded_at, capture_recorded_at)", name: "buyer_return_postings_recognition"
    t.check_constraint "recording_source::text = 'database'::text OR evidence <> '{}'::jsonb", name: "buyer_return_postings_backfill_evidence"
    t.check_constraint "recording_source::text = ANY (ARRAY['database'::character varying::text, 'backfill'::character varying::text])", name: "buyer_return_postings_recording_source_valid"
    t.check_constraint "sequence > 0", name: "buyer_return_postings_sequence_positive"
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
    t.datetime "retention_anonymized_at"
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
    t.index ["retention_anonymized_at"], name: "index_card_present_payment_attempts_on_retention_anonymized_at"
    t.check_constraint "amount_cents > 0", name: "card_present_attempts_amount_positive"
    t.check_constraint "char_length(currency::text) = 3", name: "card_present_attempts_currency_length"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2, 3])", name: "card_present_attempts_status_valid"
  end

  create_table "catalog_fulfillments", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "fulfilled_at"
    t.bigint "fulfilled_by_user_id"
    t.bigint "order_item_id", null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["fulfilled_by_user_id"], name: "index_catalog_fulfillments_on_fulfilled_by_user_id"
    t.index ["order_item_id"], name: "index_catalog_fulfillments_on_order_item_id", unique: true
    t.check_constraint "status = ANY (ARRAY[0, 1, 2])", name: "catalog_fulfillments_status_valid"
  end

  create_table "catalog_item_holds", force: :cascade do |t|
    t.bigint "catalog_item_id", null: false
    t.datetime "consumed_at"
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "order_id", null: false
    t.bigint "order_item_id", null: false
    t.integer "quantity", null: false
    t.string "release_reason"
    t.datetime "released_at"
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["catalog_item_id", "status", "expires_at"], name: "index_catalog_item_hold_inventory"
    t.index ["catalog_item_id"], name: "index_catalog_item_holds_on_catalog_item_id"
    t.index ["order_id"], name: "index_catalog_item_holds_on_order_id"
    t.index ["order_item_id"], name: "index_catalog_item_holds_on_order_item_id", unique: true
    t.check_constraint "quantity > 0", name: "catalog_item_holds_quantity_positive"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2, 3])", name: "catalog_item_holds_status_valid"
  end

  create_table "catalog_items", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.bigint "event_id", null: false
    t.integer "inventory_quantity"
    t.integer "kind", null: false
    t.integer "maximum_price_cents"
    t.integer "minimum_price_cents"
    t.string "name", null: false
    t.integer "position", default: 0, null: false
    t.integer "price_cents", default: 0, null: false
    t.integer "quantity_sold", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["event_id", "active", "position"], name: "index_catalog_items_on_event_id_and_active_and_position"
    t.index ["event_id"], name: "index_catalog_items_on_event_id"
    t.check_constraint "inventory_quantity IS NULL OR inventory_quantity > 0", name: "catalog_items_inventory_positive"
    t.check_constraint "kind = ANY (ARRAY[1, 2, 3, 4])", name: "catalog_items_kind_valid"
    t.check_constraint "price_cents >= 0 AND quantity_sold >= 0", name: "catalog_items_values_nonnegative"
  end

  create_table "checkout_attempts", force: :cascade do |t|
    t.string "checkout_key_digest", limit: 64, null: false
    t.string "request_digest", limit: 64, null: false
    t.integer "status", default: 0, null: false
    t.string "lease_token_digest", limit: 64
    t.datetime "lease_expires_at"
    t.bigint "order_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["checkout_key_digest"], name: "index_checkout_attempts_on_checkout_key_digest", unique: true
    t.index ["order_id"], name: "index_checkout_attempts_on_order_id", unique: true
    t.check_constraint "status = 0 AND order_id IS NULL AND lease_token_digest IS NOT NULL AND lease_expires_at IS NOT NULL OR status = 1 AND order_id IS NULL AND lease_token_digest IS NULL AND lease_expires_at IS NULL OR status = 2 AND order_id IS NOT NULL AND lease_token_digest IS NULL AND lease_expires_at IS NULL", name: "checkout_attempt_state"
  end

  create_table "communication_campaigns", force: :cascade do |t|
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_user_id", null: false
    t.bigint "event_id", null: false
    t.string "name", null: false
    t.integer "recipient_count", default: 0, null: false
    t.datetime "scheduled_at"
    t.jsonb "segment", default: {"type"=>"all_attendees"}, null: false
    t.datetime "sent_at"
    t.datetime "started_at"
    t.integer "status", default: 0, null: false
    t.string "subject", null: false
    t.datetime "updated_at", null: false
    t.bigint "scheduled_by_user_id"
    t.bigint "sent_by_user_id"
    t.text "last_error"
    t.index ["created_by_user_id"], name: "index_communication_campaigns_on_created_by_user_id"
    t.index ["event_id"], name: "index_communication_campaigns_on_event_id"
    t.index ["scheduled_by_user_id"], name: "index_communication_campaigns_on_scheduled_by_user_id"
    t.index ["sent_by_user_id"], name: "index_communication_campaigns_on_sent_by_user_id"
    t.index ["status", "scheduled_at"], name: "index_communication_campaigns_on_status_and_scheduled_at"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2, 3, 4, 5])", name: "communication_campaigns_status_valid"
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
    t.integer "readiness_revision", default: 1, null: false
    t.jsonb "requirements_due", default: [], null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.jsonb "payout_details", default: {}, null: false
    t.text "bank_account_number"
    t.index ["organization_id", "provider"], name: "index_connected_accounts_on_organization_id_and_provider", unique: true
    t.index ["organization_id"], name: "index_connected_accounts_on_organization_id"
    t.index ["provider", "provider_account_id"], name: "idx_connected_accounts_unique_provider_id", unique: true, where: "(provider_account_id IS NOT NULL)"
    t.check_constraint "char_length(currency::text) = 3", name: "connected_accounts_currency_length"
    t.check_constraint "jsonb_typeof(payout_details) = 'object'::text", name: "connected_accounts_payout_details_object"
    t.check_constraint "provider::text = ANY (ARRAY['paypal'::character varying::text, 'manual'::character varying::text, 'stripe'::character varying::text, 'legacy_manual'::character varying::text, 'check'::character varying::text])", name: "connected_accounts_provider_valid"
    t.check_constraint "readiness_revision > 0", name: "connected_accounts_readiness_revision_positive"
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
    t.datetime "retention_anonymized_at"
    t.datetime "loss_recorded_at"
    t.datetime "loss_reversed_at"
    t.index ["order_id"], name: "index_disputes_on_order_id"
    t.index ["payment_id"], name: "index_disputes_on_payment_id"
    t.index ["provider", "provider_dispute_id"], name: "index_disputes_on_provider_and_provider_dispute_id", unique: true
    t.index ["retention_anonymized_at"], name: "index_disputes_on_retention_anonymized_at"
    t.check_constraint "amount_cents >= 0", name: "disputes_amount_nonnegative"
    t.check_constraint "char_length(currency::text) = 3", name: "disputes_currency_length"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2])", name: "disputes_status_valid"
  end

  create_table "distribution_links", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "campaign", null: false
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_user_id", null: false
    t.bigint "distribution_partner_id", null: false
    t.bigint "event_id", null: false
    t.datetime "expires_at"
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_distribution_links_on_code", unique: true
    t.index ["created_by_user_id"], name: "index_distribution_links_on_created_by_user_id"
    t.index ["distribution_partner_id", "active"], name: "index_distribution_links_on_distribution_partner_id_and_active"
    t.index ["distribution_partner_id"], name: "index_distribution_links_on_distribution_partner_id"
    t.index ["event_id", "active"], name: "index_distribution_links_on_event_id_and_active"
    t.index ["event_id"], name: "index_distribution_links_on_event_id"
  end

  create_table "distribution_partners", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "contact_email"
    t.string "contact_name"
    t.datetime "created_at", null: false
    t.integer "kind", null: false
    t.string "name", null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.string "website_url"
    t.index ["active", "kind"], name: "index_distribution_partners_on_active_and_kind"
    t.index ["slug"], name: "index_distribution_partners_on_slug", unique: true
    t.check_constraint "kind = ANY (ARRAY[0, 1, 2, 3, 4])", name: "distribution_partners_kind_valid"
  end

  create_table "email_consents", force: :cascade do |t|
    t.string "email", null: false
    t.bigint "organization_id"
    t.string "scope", null: false
    t.string "action", null: false
    t.string "version", null: false
    t.string "source", null: false
    t.string "ip"
    t.string "user_agent"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email", "created_at"], name: "index_email_consents_on_email_and_created_at"
    t.index ["organization_id"], name: "index_email_consents_on_organization_id"
  end

  create_table "email_preferences", force: :cascade do |t|
    t.string "email", null: false
    t.boolean "all_unsubscribed", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_email_preferences_on_email", unique: true
  end

  create_table "email_rate_slots", force: :cascade do |t|
    t.string "name", null: false
    t.datetime "available_at", null: false
    t.index ["name"], name: "index_email_rate_slots_on_name", unique: true
  end

  create_table "event_cancellation_refund_items", force: :cascade do |t|
    t.bigint "event_cancellation_refund_run_id", null: false
    t.bigint "order_id", null: false
    t.integer "status", default: 0, null: false
    t.integer "amount_cents", default: 0, null: false
    t.integer "retry_generation", default: 0, null: false
    t.text "last_error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["event_cancellation_refund_run_id"], name: "index_cancellation_refund_items_on_run"
    t.index ["order_id"], name: "index_event_cancellation_refund_items_on_order_id", unique: true
  end

  create_table "event_cancellation_refund_runs", force: :cascade do |t|
    t.bigint "event_id", null: false
    t.bigint "started_by_id", null: false
    t.integer "status", default: 0, null: false
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["event_id"], name: "index_event_cancellation_refund_runs_on_event_id", unique: true
    t.index ["started_by_id"], name: "index_event_cancellation_refund_runs_on_started_by_id"
  end

  create_table "event_change_responses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "decision", null: false
    t.bigint "event_change_id", null: false
    t.bigint "order_id", null: false
    t.datetime "responded_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "requested_ticket_ids", default: [], null: false, array: true
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

  create_table "event_day_rehearsal_reviews", force: :cascade do |t|
    t.bigint "actor_user_id", null: false
    t.string "application_revision", null: false
    t.jsonb "assignments", default: {}, null: false
    t.jsonb "controls", default: {}, null: false
    t.datetime "created_at", null: false
    t.integer "decision", null: false
    t.jsonb "device_results", default: [], null: false
    t.jsonb "door_sales_results", default: {}, null: false
    t.datetime "effective_at", null: false
    t.bigint "event_id", null: false
    t.string "event_state_digest", null: false
    t.string "evidence_digest", null: false
    t.string "evidence_reference", null: false
    t.datetime "expires_at", null: false
    t.jsonb "incident_drills", default: {}, null: false
    t.jsonb "manifest_results", default: {}, null: false
    t.bigint "parent_review_id"
    t.bigint "pilot_validation_review_id", null: false
    t.text "reason"
    t.jsonb "reconciliation_results", default: {}, null: false
    t.jsonb "scan_results", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["actor_user_id"], name: "index_event_day_rehearsal_reviews_on_actor_user_id"
    t.index ["event_id", "created_at"], name: "idx_event_day_rehearsal_reviews_timeline"
    t.index ["event_id"], name: "index_event_day_rehearsal_reviews_on_event_id"
    t.index ["parent_review_id"], name: "idx_event_day_rehearsal_reviews_one_decision", unique: true, where: "((parent_review_id IS NOT NULL) AND (decision = ANY (ARRAY[1, 3])))"
    t.index ["parent_review_id"], name: "idx_event_day_rehearsal_reviews_one_revocation", unique: true, where: "((parent_review_id IS NOT NULL) AND (decision = 2))"
    t.index ["parent_review_id"], name: "index_event_day_rehearsal_reviews_on_parent_review_id"
    t.index ["pilot_validation_review_id"], name: "idx_on_pilot_validation_review_id_981bde49ad"
    t.check_constraint "decision = 0 AND parent_review_id IS NULL OR (decision = ANY (ARRAY[1, 2, 3])) AND parent_review_id IS NOT NULL", name: "event_day_rehearsal_reviews_parent_valid"
    t.check_constraint "decision = ANY (ARRAY[0, 1, 2, 3])", name: "event_day_rehearsal_reviews_decision_valid"
    t.check_constraint "evidence_digest::text ~ '^[0-9a-f]{64}$'::text AND event_state_digest::text ~ '^[0-9a-f]{64}$'::text", name: "event_day_rehearsal_reviews_digests_valid"
    t.check_constraint "expires_at > effective_at", name: "event_day_rehearsal_reviews_window_valid"
  end

  create_table "event_favorites", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "event_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["event_id"], name: "index_event_favorites_on_event_id"
    t.index ["user_id", "event_id"], name: "index_event_favorites_on_user_id_and_event_id", unique: true
    t.index ["user_id"], name: "index_event_favorites_on_user_id"
  end

  create_table "event_price_zones", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "event_seating_configuration_id", null: false
    t.bigint "seating_price_zone_id", null: false
    t.bigint "ticket_type_id", null: false
    t.datetime "updated_at", null: false
    t.index ["event_seating_configuration_id", "seating_price_zone_id"], name: "index_event_price_zones_on_configuration_and_zone", unique: true
    t.index ["event_seating_configuration_id"], name: "index_event_price_zones_on_configuration_id"
    t.index ["seating_price_zone_id"], name: "index_event_price_zones_on_seating_price_zone_id"
    t.index ["ticket_type_id"], name: "index_event_price_zones_on_ticket_type_id"
  end

  create_table "event_referrals", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.bigint "event_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["code"], name: "index_event_referrals_on_code", unique: true
    t.index ["event_id"], name: "index_event_referrals_on_event_id"
    t.index ["user_id", "event_id"], name: "index_event_referrals_on_user_id_and_event_id", unique: true
    t.index ["user_id"], name: "index_event_referrals_on_user_id"
  end

  create_table "event_reminders", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "event_id", null: false
    t.datetime "remind_at", null: false
    t.datetime "sent_at"
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["event_id"], name: "index_event_reminders_on_event_id"
    t.index ["status", "remind_at"], name: "index_event_reminders_on_status_and_remind_at"
    t.index ["user_id", "event_id"], name: "index_event_reminders_on_user_id_and_event_id", unique: true
    t.index ["user_id"], name: "index_event_reminders_on_user_id"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2])", name: "event_reminders_status_valid"
  end

  create_table "event_seating_configurations", force: :cascade do |t|
    t.datetime "activated_at"
    t.datetime "created_at", null: false
    t.bigint "event_id", null: false
    t.string "provider_event_key"
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.bigint "venue_layout_id", null: false
    t.index ["event_id"], name: "index_event_seating_configurations_on_event_id", unique: true
    t.index ["venue_layout_id"], name: "index_event_seating_configurations_on_venue_layout_id"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2])", name: "event_seating_configurations_status_valid"
  end

  create_table "event_seats", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "event_seating_configuration_id", null: false
    t.datetime "general_release_at"
    t.integer "operational_status", default: 0, null: false
    t.string "status_reason"
    t.bigint "ticket_type_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "venue_seat_id", null: false
    t.index ["event_seating_configuration_id", "ticket_type_id"], name: "idx_on_event_seating_configuration_id_ticket_type_i_3c06f89e8e"
    t.index ["event_seating_configuration_id", "venue_seat_id"], name: "index_event_seats_on_configuration_and_venue_seat", unique: true
    t.index ["event_seating_configuration_id"], name: "index_event_seats_on_configuration_id"
    t.index ["ticket_type_id"], name: "index_event_seats_on_ticket_type_id"
    t.index ["venue_seat_id"], name: "index_event_seats_on_venue_seat_id"
    t.check_constraint "operational_status = ANY (ARRAY[0, 1, 2])", name: "event_seats_status_valid"
  end

  create_table "event_series", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.string "name", null: false
    t.string "slug", null: false
    t.text "description"
    t.integer "status", default: 0, null: false
    t.integer "revenue_share_bps"
    t.string "revenue_share_base", default: "admissions_net_proceeds", null: false
    t.boolean "revenue_share_includes_door_cash", default: false, null: false
    t.string "revenue_share_label"
    t.string "primary_share_label"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "slug"], name: "index_event_series_on_organization_id_and_slug", unique: true
    t.index ["organization_id"], name: "index_event_series_on_organization_id"
    t.check_constraint "revenue_share_base::text = ANY (ARRAY['admissions_net_proceeds'::character varying::text, 'admissions_gross'::character varying::text, 'admissions_net_after_processing'::character varying::text, 'all_net_proceeds'::character varying::text])", name: "chk_event_series_revenue_share_base"
    t.check_constraint "revenue_share_bps IS NULL OR revenue_share_bps >= 0 AND revenue_share_bps <= 10000", name: "chk_event_series_revenue_share_bps"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2, 3])", name: "chk_event_series_status"
  end

  create_table "event_series_memberships", force: :cascade do |t|
    t.bigint "event_series_id", null: false
    t.bigint "event_id", null: false
    t.integer "role", default: 0, null: false
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["event_id"], name: "index_event_series_memberships_on_event_id"
    t.index ["event_series_id", "event_id"], name: "index_event_series_memberships_on_event_series_id_and_event_id", unique: true
    t.check_constraint "\"position\" >= 0", name: "chk_event_series_memberships_position"
    t.check_constraint "role = ANY (ARRAY[0, 1, 2, 3, 4])", name: "chk_event_series_memberships_role"
  end

  create_table "event_slug_redirects", force: :cascade do |t|
    t.bigint "event_id", null: false
    t.string "slug", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["event_id"], name: "index_event_slug_redirects_on_event_id"
    t.index ["slug"], name: "index_event_slug_redirects_on_slug", unique: true
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
    t.check_constraint "role = ANY (ARRAY[0, 1, 2, 3])", name: "event_staff_assignments_role_valid_re_entry"
    t.check_constraint "status = ANY (ARRAY[0, 1])", name: "event_staff_assignments_status_valid"
  end

  create_table "event_state_changes", force: :cascade do |t|
    t.string "action", null: false
    t.bigint "actor_user_id"
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

  create_table "event_waivers", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.text "body", null: false
    t.string "content_digest", null: false
    t.datetime "created_at", null: false
    t.bigint "event_id", null: false
    t.boolean "required", default: true, null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.string "version", null: false
    t.index ["event_id", "version"], name: "index_event_waivers_on_event_id_and_version", unique: true
    t.index ["event_id"], name: "index_event_waivers_on_event_id"
  end

  create_table "events", force: :cascade do |t|
    t.integer "age_restriction", default: 0
    t.integer "buyer_fee_percent", default: 100, null: false
    t.integer "category", default: 5
    t.string "cover_image_url"
    t.datetime "created_at", null: false
    t.text "description"
    t.datetime "doors_open_at"
    t.datetime "ends_at"
    t.integer "fee_policy", default: 0, null: false
    t.boolean "is_featured", default: false
    t.boolean "live_money_proof_candidate", default: false, null: false
    t.jsonb "localized_content", default: {}, null: false
    t.integer "max_capacity"
    t.bigint "organization_id", null: false
    t.bigint "organizer_profile_id", null: false
    t.datetime "published_at"
    t.date "recurrence_end_date"
    t.integer "recurrence_parent_id"
    t.string "recurrence_rule"
    t.datetime "sales_suspended_at"
    t.string "sales_suspension_reason"
    t.string "short_description"
    t.boolean "show_attendees", default: true
    t.string "slug", null: false
    t.datetime "starts_at"
    t.integer "status", default: 0
    t.jsonb "supported_locales", default: ["en"], null: false
    t.string "timezone", default: "Pacific/Guam"
    t.string "title", null: false
    t.boolean "transfers_enabled", default: true, null: false
    t.datetime "updated_at", null: false
    t.string "venue_address"
    t.string "venue_city"
    t.bigint "venue_id"
    t.string "venue_name"
    t.boolean "custom_slug", default: false, null: false
    t.datetime "policy_hold_at"
    t.string "policy_hold_scope"
    t.text "policy_hold_reason"
    t.bigint "policy_hold_by_user_id"
    t.jsonb "translations", default: {}, null: false
    t.string "translation_status", default: "untranslated", null: false
    t.datetime "translation_requested_at"
    t.jsonb "localized_content_sources", default: {}, null: false
    t.jsonb "page_customization", default: {}, null: false
    t.string "preview_token_digest"
    t.integer "preview_token_version", default: 0, null: false
    t.datetime "organizer_sales_suspended_at"
    t.text "organizer_sales_suspension_reason"
    t.boolean "online_door_card_enabled", default: false, null: false
    t.string "re_entry_mode", default: "off", null: false
    t.integer "re_entry_max_count"
    t.integer "re_entry_cooldown_minutes"
    t.string "re_entry_cutoff_time"
    t.index "lower(translate((venue_city)::text, 'åàáâäãāéèêëēíìîïīóòôöõōúùûüūñÅÀÁÂÄÃĀÉÈÊËĒÍÌÎÏĪÓÒÔÖÕŌÚÙÛÜŪÑ'::text, 'aaaaaaaeeeeeiiiiioooooouuuuunaaaaaaaeeeeeiiiiioooooouuuuun'::text))", name: "index_events_on_folded_venue_city"
    t.index ["live_money_proof_candidate"], name: "index_events_on_live_money_proof_candidate"
    t.index ["organization_id"], name: "index_events_on_organization_id"
    t.index ["organizer_profile_id"], name: "index_events_on_organizer_profile_id"
    t.index ["policy_hold_at"], name: "index_events_on_policy_hold_at", where: "(policy_hold_at IS NOT NULL)"
    t.index ["recurrence_parent_id"], name: "index_events_on_recurrence_parent_id"
    t.index ["slug"], name: "index_events_on_slug", unique: true
    t.index ["starts_at"], name: "index_events_on_starts_at"
    t.index ["status", "starts_at", "category"], name: "index_events_discovery"
    t.index ["status"], name: "index_events_on_status"
    t.index ["venue_id"], name: "index_events_on_venue_id"
    t.check_constraint "buyer_fee_percent >= 0 AND buyer_fee_percent <= 100", name: "events_buyer_fee_percent_valid"
    t.check_constraint "fee_policy = ANY (ARRAY[0, 1, 2])", name: "events_fee_policy_valid"
    t.check_constraint "max_capacity IS NULL OR max_capacity > 0", name: "events_capacity_positive"
    t.check_constraint "policy_hold_at IS NULL AND policy_hold_scope IS NULL AND policy_hold_reason IS NULL OR policy_hold_at IS NOT NULL AND (policy_hold_scope::text = ANY (ARRAY['sales'::character varying::text, 'hidden'::character varying::text])) AND char_length(btrim(policy_hold_reason)) > 0", name: "events_policy_hold_consistent"
    t.check_constraint "re_entry_cooldown_minutes IS NULL OR re_entry_cooldown_minutes > 0", name: "events_re_entry_cooldown_positive"
    t.check_constraint "re_entry_cutoff_time IS NULL OR re_entry_cutoff_time::text ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'::text", name: "events_re_entry_cutoff_time_valid"
    t.check_constraint "re_entry_max_count IS NULL OR re_entry_max_count > 0", name: "events_re_entry_max_count_positive"
    t.check_constraint "re_entry_mode::text = ANY (ARRAY['off'::character varying::text, 'exit_scan'::character varying::text, 'cooldown'::character varying::text])", name: "events_re_entry_mode_valid"
  end

  create_table "fee_change_notices", force: :cascade do |t|
    t.bigint "fee_change_id", null: false
    t.bigint "organization_id", null: false
    t.bigint "owner_id", null: false
    t.string "recipient_email", null: false
    t.integer "buyer_fee_percent", null: false
    t.string "fee_policy", null: false
    t.bigint "event_id", null: false
    t.datetime "acknowledged_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["fee_change_id", "organization_id", "owner_id"], name: "fee_change_notice_recipient_uniqueness", unique: true
    t.index ["fee_change_id"], name: "index_fee_change_notices_on_fee_change_id"
    t.index ["organization_id"], name: "index_fee_change_notices_on_organization_id"
    t.index ["owner_id"], name: "index_fee_change_notices_on_owner_id"
  end

  create_table "fee_changes", force: :cascade do |t|
    t.bigint "created_by_id", null: false
    t.jsonb "old_terms", null: false
    t.jsonb "new_terms", null: false
    t.datetime "effective_at", null: false
    t.datetime "activated_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "preapproval_id"
    t.string "preapproved_registry_digest"
    t.datetime "blocked_at"
    t.string "activation_error"
    t.index "(1)", name: "one_pending_fee_change", unique: true, where: "((activated_at IS NULL) AND (blocked_at IS NULL))"
    t.index ["blocked_at"], name: "index_fee_changes_on_blocked_at"
    t.index ["created_by_id"], name: "index_fee_changes_on_created_by_id"
    t.index ["effective_at"], name: "index_fee_changes_on_effective_at"
    t.index ["preapproval_id"], name: "index_fee_changes_on_preapproval_id"
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
    t.datetime "retention_anonymized_at"
    t.index ["order_id"], name: "index_fee_components_on_order_id"
    t.index ["order_item_id"], name: "index_fee_components_on_order_item_id"
    t.index ["retention_anonymized_at"], name: "index_fee_components_on_retention_anonymized_at"
    t.check_constraint "amount_cents >= 0", name: "fee_components_amount_nonnegative"
    t.check_constraint "char_length(currency::text) = 3", name: "fee_components_currency_length"
  end

  create_table "financial_cutovers", force: :cascade do |t|
    t.string "key", null: false
    t.datetime "recorded_at", default: -> { "timezone('UTC'::text, clock_timestamp())" }, null: false
    t.index ["key"], name: "index_financial_cutovers_on_key", unique: true
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
    t.datetime "retention_anonymized_at"
    t.index ["event_id", "guest_email"], name: "index_guest_list_entries_on_event_id_and_guest_email"
    t.index ["event_id"], name: "index_guest_list_entries_on_event_id"
    t.index ["order_id"], name: "index_guest_list_entries_on_order_id"
    t.index ["retention_anonymized_at"], name: "index_guest_list_entries_on_retention_anonymized_at"
    t.index ["ticket_type_id"], name: "index_guest_list_entries_on_ticket_type_id"
  end

  create_table "image_upload_receipts", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "organization_id", null: false
    t.bigint "event_id"
    t.string "source_key", null: false
    t.string "final_key", null: false
    t.string "public_url"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["event_id"], name: "index_image_upload_receipts_on_event_id"
    t.index ["organization_id"], name: "index_image_upload_receipts_on_organization_id"
    t.index ["source_key"], name: "index_image_upload_receipts_on_source_key", unique: true
    t.index ["user_id"], name: "index_image_upload_receipts_on_user_id"
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

  create_table "legal_holds", force: :cascade do |t|
    t.string "scope_type", null: false
    t.string "scope_value", null: false
    t.text "reason", null: false
    t.bigint "placed_by_id", null: false
    t.bigint "released_by_id"
    t.datetime "released_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["placed_by_id"], name: "index_legal_holds_on_placed_by_id"
    t.index ["released_by_id"], name: "index_legal_holds_on_released_by_id"
    t.index ["scope_type", "scope_value"], name: "index_active_legal_holds_on_scope", unique: true, where: "(released_at IS NULL)"
  end

  create_table "live_money_proof_authorizations", force: :cascade do |t|
    t.string "application_revision", null: false
    t.datetime "approved_at"
    t.bigint "approved_by_user_id"
    t.string "buyer_email_digest", null: false
    t.bigint "connected_account_id", null: false
    t.datetime "consumed_at"
    t.datetime "created_at", null: false
    t.bigint "event_day_rehearsal_review_id", null: false
    t.bigint "event_id", null: false
    t.string "event_state_digest", null: false
    t.datetime "expires_at", null: false
    t.integer "max_amount_cents", null: false
    t.bigint "order_id"
    t.string "platform_configuration_digest", null: false
    t.string "provider_state_digest", null: false
    t.bigint "requested_by_user_id", null: false
    t.text "revocation_reason"
    t.datetime "revoked_at"
    t.datetime "updated_at", null: false
    t.index ["approved_by_user_id"], name: "index_live_money_proof_authorizations_on_approved_by_user_id"
    t.index ["connected_account_id"], name: "index_live_money_proof_authorizations_on_connected_account_id"
    t.index ["event_day_rehearsal_review_id"], name: "idx_on_event_day_rehearsal_review_id_75d99fc8d7"
    t.index ["event_id", "created_at"], name: "idx_live_money_authorizations_timeline"
    t.index ["event_id"], name: "index_live_money_proof_authorizations_on_event_id"
    t.index ["order_id"], name: "idx_live_money_authorizations_unique_order", unique: true, where: "(order_id IS NOT NULL)"
    t.index ["order_id"], name: "index_live_money_proof_authorizations_on_order_id"
    t.index ["requested_by_user_id"], name: "index_live_money_proof_authorizations_on_requested_by_user_id"
    t.check_constraint "approved_at IS NULL AND approved_by_user_id IS NULL OR approved_at IS NOT NULL AND approved_by_user_id IS NOT NULL", name: "live_money_authorizations_approval_valid"
    t.check_constraint "buyer_email_digest::text ~ '^[0-9a-f]{64}$'::text AND event_state_digest::text ~ '^[0-9a-f]{64}$'::text AND provider_state_digest::text ~ '^[0-9a-f]{64}$'::text AND platform_configuration_digest::text ~ '^[0-9a-f]{64}$'::text", name: "live_money_authorizations_digests_valid"
    t.check_constraint "consumed_at IS NULL AND order_id IS NULL OR consumed_at IS NOT NULL AND order_id IS NOT NULL", name: "live_money_authorizations_consumption_valid"
    t.check_constraint "max_amount_cents > 0 AND max_amount_cents <= 500", name: "live_money_authorizations_amount_valid"
    t.check_constraint "revoked_at IS NULL AND revocation_reason IS NULL OR revoked_at IS NOT NULL AND revocation_reason IS NOT NULL AND length(btrim(revocation_reason)) > 0", name: "live_money_authorizations_revocation_valid"
  end

  create_table "live_money_proof_reviews", force: :cascade do |t|
    t.bigint "actor_user_id", null: false
    t.string "application_revision", null: false
    t.bigint "authorization_id", null: false
    t.jsonb "communication_results", default: {}, null: false
    t.bigint "connected_account_id", null: false
    t.jsonb "controls", default: {}, null: false
    t.datetime "created_at", null: false
    t.integer "decision", null: false
    t.datetime "effective_at", null: false
    t.jsonb "entity_results", default: {}, null: false
    t.bigint "event_day_rehearsal_review_id", null: false
    t.string "evidence_digest", null: false
    t.string "evidence_reference", null: false
    t.datetime "expires_at", null: false
    t.bigint "final_refund_id", null: false
    t.bigint "initial_settlement_id", null: false
    t.bigint "order_id", null: false
    t.bigint "organization_id", null: false
    t.bigint "parent_review_id"
    t.bigint "partial_refund_id", null: false
    t.bigint "payment_id", null: false
    t.bigint "payout_id", null: false
    t.string "platform_configuration_digest", null: false
    t.bigint "post_payout_settlement_id", null: false
    t.bigint "proof_event_id", null: false
    t.jsonb "provider_results", default: {}, null: false
    t.string "provider_state_digest", null: false
    t.text "reason"
    t.jsonb "reconciliation_results", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["actor_user_id"], name: "index_live_money_proof_reviews_on_actor_user_id"
    t.index ["authorization_id"], name: "index_live_money_proof_reviews_on_authorization_id"
    t.index ["connected_account_id"], name: "index_live_money_proof_reviews_on_connected_account_id"
    t.index ["event_day_rehearsal_review_id"], name: "idx_on_event_day_rehearsal_review_id_b090a5215f"
    t.index ["final_refund_id"], name: "index_live_money_proof_reviews_on_final_refund_id"
    t.index ["initial_settlement_id"], name: "index_live_money_proof_reviews_on_initial_settlement_id"
    t.index ["order_id"], name: "index_live_money_proof_reviews_on_order_id"
    t.index ["organization_id", "created_at"], name: "idx_live_money_proof_reviews_timeline"
    t.index ["organization_id"], name: "index_live_money_proof_reviews_on_organization_id"
    t.index ["parent_review_id"], name: "idx_live_money_proof_reviews_one_decision", unique: true, where: "((parent_review_id IS NOT NULL) AND (decision = ANY (ARRAY[1, 3])))"
    t.index ["parent_review_id"], name: "idx_live_money_proof_reviews_one_revocation", unique: true, where: "((parent_review_id IS NOT NULL) AND (decision = 2))"
    t.index ["parent_review_id"], name: "index_live_money_proof_reviews_on_parent_review_id"
    t.index ["partial_refund_id"], name: "index_live_money_proof_reviews_on_partial_refund_id"
    t.index ["payment_id"], name: "index_live_money_proof_reviews_on_payment_id"
    t.index ["payout_id"], name: "index_live_money_proof_reviews_on_payout_id"
    t.index ["post_payout_settlement_id"], name: "index_live_money_proof_reviews_on_post_payout_settlement_id"
    t.index ["proof_event_id"], name: "index_live_money_proof_reviews_on_proof_event_id"
    t.check_constraint "decision = 0 AND parent_review_id IS NULL OR (decision = ANY (ARRAY[1, 2, 3])) AND parent_review_id IS NOT NULL", name: "live_money_proof_reviews_parent_valid"
    t.check_constraint "decision = ANY (ARRAY[0, 1, 2, 3])", name: "live_money_proof_reviews_decision_valid"
    t.check_constraint "evidence_digest::text ~ '^[0-9a-f]{64}$'::text AND provider_state_digest::text ~ '^[0-9a-f]{64}$'::text AND platform_configuration_digest::text ~ '^[0-9a-f]{64}$'::text", name: "live_money_proof_reviews_digests_valid"
    t.check_constraint "expires_at > effective_at", name: "live_money_proof_reviews_window_valid"
  end

  create_table "live_pilot_incidents", force: :cascade do |t|
    t.integer "action", null: false
    t.bigint "actor_user_id", null: false
    t.string "category", null: false
    t.datetime "created_at", null: false
    t.bigint "event_id", null: false
    t.string "evidence_digest", null: false
    t.string "evidence_reference", null: false
    t.bigint "live_pilot_run_id", null: false
    t.datetime "occurred_at", null: false
    t.bigint "parent_incident_id"
    t.integer "severity", null: false
    t.text "summary", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_user_id"], name: "index_live_pilot_incidents_on_actor_user_id"
    t.index ["event_id"], name: "index_live_pilot_incidents_on_event_id"
    t.index ["live_pilot_run_id", "occurred_at"], name: "idx_live_pilot_incidents_timeline"
    t.index ["live_pilot_run_id"], name: "index_live_pilot_incidents_on_live_pilot_run_id"
    t.index ["parent_incident_id"], name: "idx_live_pilot_incidents_one_resolution", unique: true, where: "((parent_incident_id IS NOT NULL) AND (action = 1))"
    t.index ["parent_incident_id"], name: "index_live_pilot_incidents_on_parent_incident_id"
    t.check_constraint "action = 0 AND parent_incident_id IS NULL OR action = 1 AND parent_incident_id IS NOT NULL", name: "live_pilot_incidents_parent_valid"
    t.check_constraint "action = ANY (ARRAY[0, 1])", name: "live_pilot_incidents_action_valid"
    t.check_constraint "evidence_digest::text ~ '^[0-9a-f]{64}$'::text", name: "live_pilot_incidents_digest_valid"
    t.check_constraint "severity = ANY (ARRAY[0, 1, 2, 3])", name: "live_pilot_incidents_severity_valid"
  end

  create_table "live_pilot_metric_snapshots", force: :cascade do |t|
    t.jsonb "breached_thresholds", default: {}, null: false
    t.datetime "created_at", null: false
    t.bigint "event_id", null: false
    t.string "evidence_digest", null: false
    t.string "evidence_reference", null: false
    t.jsonb "external_metrics", default: {}, null: false
    t.bigint "live_pilot_run_id", null: false
    t.jsonb "local_metrics", default: {}, null: false
    t.datetime "observed_at", null: false
    t.bigint "recorded_by_user_id", null: false
    t.datetime "updated_at", null: false
    t.index ["event_id"], name: "index_live_pilot_metric_snapshots_on_event_id"
    t.index ["live_pilot_run_id", "observed_at"], name: "idx_live_pilot_metrics_timeline"
    t.index ["live_pilot_run_id"], name: "index_live_pilot_metric_snapshots_on_live_pilot_run_id"
    t.index ["recorded_by_user_id"], name: "index_live_pilot_metric_snapshots_on_recorded_by_user_id"
    t.check_constraint "evidence_digest::text ~ '^[0-9a-f]{64}$'::text", name: "live_pilot_metrics_digest_valid"
  end

  create_table "live_pilot_reviews", force: :cascade do |t|
    t.bigint "actor_user_id", null: false
    t.string "application_revision", null: false
    t.jsonb "assignments", default: {}, null: false
    t.jsonb "controls", default: {}, null: false
    t.datetime "created_at", null: false
    t.integer "decision", null: false
    t.datetime "effective_at", null: false
    t.bigint "event_day_rehearsal_review_id", null: false
    t.bigint "event_id", null: false
    t.string "event_state_digest", null: false
    t.string "evidence_digest", null: false
    t.string "evidence_reference", null: false
    t.datetime "expires_at", null: false
    t.integer "inventory_cap", null: false
    t.bigint "live_money_proof_review_id"
    t.bigint "parent_review_id"
    t.text "reason"
    t.jsonb "support_coverage", default: {}, null: false
    t.jsonb "thresholds", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["actor_user_id"], name: "index_live_pilot_reviews_on_actor_user_id"
    t.index ["event_day_rehearsal_review_id"], name: "index_live_pilot_reviews_on_event_day_rehearsal_review_id"
    t.index ["event_id", "created_at"], name: "idx_live_pilot_reviews_timeline"
    t.index ["event_id"], name: "index_live_pilot_reviews_on_event_id"
    t.index ["live_money_proof_review_id"], name: "index_live_pilot_reviews_on_live_money_proof_review_id"
    t.index ["parent_review_id"], name: "idx_live_pilot_reviews_one_approval", unique: true, where: "((parent_review_id IS NOT NULL) AND (decision = 1))"
    t.index ["parent_review_id"], name: "idx_live_pilot_reviews_one_rejection", unique: true, where: "((parent_review_id IS NOT NULL) AND (decision = 3))"
    t.index ["parent_review_id"], name: "idx_live_pilot_reviews_one_revocation", unique: true, where: "((parent_review_id IS NOT NULL) AND (decision = 2))"
    t.index ["parent_review_id"], name: "index_live_pilot_reviews_on_parent_review_id"
    t.check_constraint "decision = 0 AND parent_review_id IS NULL OR (decision = ANY (ARRAY[1, 2, 3])) AND parent_review_id IS NOT NULL", name: "live_pilot_reviews_parent_valid"
    t.check_constraint "decision = ANY (ARRAY[0, 1, 2, 3])", name: "live_pilot_reviews_decision_valid"
    t.check_constraint "evidence_digest::text ~ '^[0-9a-f]{64}$'::text AND event_state_digest::text ~ '^[0-9a-f]{64}$'::text", name: "live_pilot_reviews_digests_valid"
    t.check_constraint "expires_at > effective_at", name: "live_pilot_reviews_window_valid"
    t.check_constraint "inventory_cap > 0 AND inventory_cap <= 250", name: "live_pilot_reviews_inventory_cap_valid"
  end

  create_table "live_pilot_run_actions", force: :cascade do |t|
    t.bigint "actor_user_id"
    t.datetime "created_at", null: false
    t.jsonb "details", default: {}, null: false
    t.bigint "event_id", null: false
    t.integer "kind", null: false
    t.bigint "live_pilot_run_id", null: false
    t.datetime "occurred_at", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_user_id"], name: "index_live_pilot_run_actions_on_actor_user_id"
    t.index ["event_id"], name: "index_live_pilot_run_actions_on_event_id"
    t.index ["live_pilot_run_id", "occurred_at"], name: "idx_live_pilot_actions_timeline"
    t.index ["live_pilot_run_id"], name: "index_live_pilot_run_actions_on_live_pilot_run_id"
    t.check_constraint "kind = ANY (ARRAY[0, 1, 2, 3, 4])", name: "live_pilot_run_actions_kind_valid"
  end

  create_table "live_pilot_runs", force: :cascade do |t|
    t.text "abort_reason"
    t.datetime "aborted_at"
    t.datetime "completed_at"
    t.bigint "completed_by_user_id"
    t.string "completion_evidence_digest"
    t.string "completion_evidence_reference"
    t.jsonb "completion_results", default: {}, null: false
    t.datetime "created_at", null: false
    t.bigint "event_id", null: false
    t.bigint "live_pilot_review_id", null: false
    t.text "pause_reason"
    t.datetime "paused_at"
    t.datetime "started_at", null: false
    t.bigint "started_by_user_id", null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["completed_by_user_id"], name: "index_live_pilot_runs_on_completed_by_user_id"
    t.index ["event_id", "created_at"], name: "idx_live_pilot_runs_timeline"
    t.index ["event_id"], name: "idx_live_pilot_runs_one_open", unique: true, where: "(status = ANY (ARRAY[0, 1]))"
    t.index ["event_id"], name: "index_live_pilot_runs_on_event_id"
    t.index ["live_pilot_review_id"], name: "index_live_pilot_runs_on_live_pilot_review_id", unique: true
    t.index ["started_by_user_id"], name: "index_live_pilot_runs_on_started_by_user_id"
    t.check_constraint "completion_evidence_digest IS NULL OR completion_evidence_digest::text ~ '^[0-9a-f]{64}$'::text", name: "live_pilot_runs_completion_digest_valid"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2, 3])", name: "live_pilot_runs_status_valid"
  end

  create_table "marketing_unsubscribes", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.string "email", null: false
    t.datetime "unsubscribed_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "email"], name: "index_marketing_unsubscribes_on_organization_id_and_email", unique: true
    t.index ["organization_id"], name: "index_marketing_unsubscribes_on_organization_id"
  end

  create_table "marketplace_collection_events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "event_id", null: false
    t.bigint "marketplace_collection_id", null: false
    t.integer "position", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["event_id"], name: "index_marketplace_collection_events_on_event_id"
    t.index ["marketplace_collection_id", "event_id"], name: "index_collection_events_unique", unique: true
    t.index ["marketplace_collection_id", "position"], name: "index_collection_events_position"
    t.index ["marketplace_collection_id"], name: "idx_on_marketplace_collection_id_32110578bf"
  end

  create_table "marketplace_collections", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "created_by_user_id", null: false
    t.text "description"
    t.datetime "ends_at"
    t.integer "position", default: 0, null: false
    t.string "seo_description"
    t.string "seo_title"
    t.string "slug", null: false
    t.datetime "starts_at"
    t.integer "status", default: 0, null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_user_id"], name: "index_marketplace_collections_on_created_by_user_id"
    t.index ["slug"], name: "index_marketplace_collections_on_slug", unique: true
    t.index ["status", "position"], name: "index_marketplace_collections_on_status_and_position"
    t.check_constraint "ends_at IS NULL OR starts_at IS NULL OR ends_at > starts_at", name: "marketplace_collections_dates_valid"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2])", name: "marketplace_collections_status_valid"
  end

  create_table "marketplace_funnel_events", force: :cascade do |t|
    t.string "campaign"
    t.datetime "created_at", null: false
    t.bigint "distribution_link_id"
    t.bigint "event_id", null: false
    t.bigint "event_referral_id"
    t.string "medium"
    t.datetime "occurred_at", null: false
    t.bigint "order_id"
    t.string "source"
    t.integer "stage", null: false
    t.datetime "updated_at", null: false
    t.string "visitor_hash", null: false
    t.index ["distribution_link_id"], name: "index_marketplace_funnel_events_on_distribution_link_id"
    t.index ["event_id", "stage", "occurred_at"], name: "index_funnel_event_stage_time"
    t.index ["event_id"], name: "index_marketplace_funnel_events_on_event_id"
    t.index ["event_referral_id"], name: "index_marketplace_funnel_events_on_event_referral_id"
    t.index ["order_id", "stage"], name: "index_funnel_order_stage_unique", unique: true, where: "(order_id IS NOT NULL)"
    t.index ["order_id"], name: "index_marketplace_funnel_events_on_order_id"
    t.index ["visitor_hash", "occurred_at"], name: "index_funnel_visitor_time"
    t.check_constraint "stage = ANY (ARRAY[0, 1, 2, 3])", name: "marketplace_funnel_stage_valid"
  end

  create_table "message_deliveries", force: :cascade do |t|
    t.integer "attempts", default: 0, null: false
    t.datetime "bounced_at"
    t.string "channel", default: "email", null: false
    t.bigint "communication_campaign_id"
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
    t.jsonb "outbound_payload", default: {}, null: false
    t.datetime "provider_attempted_at"
    t.boolean "provider_outcome_unknown", default: false, null: false
    t.string "send_lease_token"
    t.datetime "send_lease_expires_at"
    t.string "transport_context_digest"
    t.text "outbound_wire_body"
    t.string "wire_body_digest"
    t.bigint "organization_membership_id"
    t.bigint "platform_invitation_id"
    t.bigint "privacy_request_id"
    t.datetime "retention_anonymized_at"
    t.datetime "reconciled_at"
    t.datetime "replay_requested_at"
    t.bigint "audience_mailing_id"
    t.bigint "platform_subscriber_id"
    t.index "lower((recipient)::text)", name: "index_message_deliveries_lower_recipient"
    t.index ["audience_mailing_id"], name: "index_message_deliveries_on_audience_mailing_id"
    t.index ["communication_campaign_id"], name: "index_message_deliveries_on_communication_campaign_id"
    t.index ["created_at", "id"], name: "idx_waitlist_deliveries_pending_reconciliation", where: "((reconciled_at IS NULL) AND ((template)::text = ANY (ARRAY[('waitlist_notification'::character varying)::text, ('waitlist_offer'::character varying)::text])) AND (status = ANY (ARRAY[2, 3, 6, 7])))"
    t.index ["event_id"], name: "index_message_deliveries_on_event_id"
    t.index ["idempotency_key"], name: "index_message_deliveries_on_idempotency_key", unique: true
    t.index ["order_id", "created_at"], name: "index_message_deliveries_on_order_id_and_created_at"
    t.index ["order_id"], name: "index_message_deliveries_on_order_id"
    t.index ["organization_membership_id"], name: "index_message_deliveries_on_organization_membership_id"
    t.index ["platform_invitation_id"], name: "index_message_deliveries_on_platform_invitation_id"
    t.index ["platform_subscriber_id"], name: "index_message_deliveries_on_platform_subscriber_id"
    t.index ["privacy_request_id"], name: "index_message_deliveries_on_privacy_request_id"
    t.index ["provider_id"], name: "index_message_deliveries_on_provider_id"
    t.index ["requested_by_id"], name: "index_message_deliveries_on_requested_by_id"
    t.index ["retention_anonymized_at"], name: "index_message_deliveries_on_retention_anonymized_at"
    t.index ["status", "updated_at"], name: "index_message_deliveries_on_status_and_updated_at"
    t.index ["ticket_id"], name: "index_message_deliveries_on_ticket_id"
    t.check_constraint "attempts >= 0", name: "message_deliveries_attempts_nonnegative"
    t.check_constraint "order_id IS NOT NULL OR ticket_id IS NOT NULL OR event_id IS NOT NULL OR organization_membership_id IS NOT NULL OR platform_invitation_id IS NOT NULL OR privacy_request_id IS NOT NULL OR audience_mailing_id IS NOT NULL OR platform_subscriber_id IS NOT NULL", name: "message_deliveries_subject_present_email_base"
    t.check_constraint "outbound_wire_body IS NULL AND wire_body_digest IS NULL OR outbound_wire_body IS NOT NULL AND wire_body_digest IS NOT NULL AND wire_body_digest::text = encode(sha256(convert_to(outbound_wire_body, 'UTF8'::name)), 'hex'::text)", name: "message_deliveries_wire_digest_matches"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2, 3, 4, 5, 6, 7, 8])", name: "message_deliveries_status_valid"
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
    t.datetime "retention_anonymized_at"
    t.index ["message_delivery_id"], name: "index_message_provider_events_on_message_delivery_id"
    t.index ["provider", "provider_event_id"], name: "index_message_provider_events_on_provider_event", unique: true
    t.index ["provider_message_id", "occurred_at"], name: "idx_on_provider_message_id_occurred_at_71bff7dab0"
    t.index ["retention_anonymized_at"], name: "index_message_provider_events_on_retention_anonymized_at"
  end

  create_table "never_fulfilled_captures", force: :cascade do |t|
    t.bigint "order_id", null: false
    t.bigint "payment_id", null: false
    t.string "capture_scope", null: false
    t.string "code", null: false
    t.integer "captured_cents", null: false
    t.string "currency", null: false
    t.integer "proceeds_cents", null: false
    t.integer "fee_cents", null: false
    t.integer "organizer_fee_cents", null: false
    t.integer "tax_cents", null: false
    t.datetime "capture_recorded_at", null: false
    t.string "processing_bearer", null: false
    t.string "dispute_fee_bearer", null: false
    t.string "allocation_policy", null: false
    t.string "policy_version", null: false
    t.string "provenance", null: false
    t.jsonb "provenance_evidence", default: {}, null: false
    t.datetime "created_at", default: -> { "timezone('UTC'::text, clock_timestamp())" }, null: false
    t.index ["order_id"], name: "index_never_fulfilled_captures_on_order_id"
    t.index ["payment_id"], name: "index_never_fulfilled_captures_on_payment_id", unique: true
    t.check_constraint "(proceeds_cents + fee_cents + organizer_fee_cents + tax_cents) = captured_cents", name: "never_fulfilled_captures_components_sum"
    t.check_constraint "(processing_bearer::text = ANY (ARRAY['platform'::character varying::text, 'organizer'::character varying::text])) AND (dispute_fee_bearer::text = ANY (ARRAY['platform'::character varying::text, 'organizer'::character varying::text]))", name: "never_fulfilled_captures_bearers_valid"
    t.check_constraint "allocation_policy::text = ANY (ARRAY['item_record'::character varying::text, 'cumulative_pro_rata'::character varying::text])", name: "never_fulfilled_captures_allocation_policy_valid"
    t.check_constraint "capture_scope::text = 'order'::text OR fee_cents = 0 AND organizer_fee_cents = 0 AND tax_cents = 0", name: "never_fulfilled_captures_payment_scope_principal"
    t.check_constraint "capture_scope::text = ANY (ARRAY['order'::character varying::text, 'payment'::character varying::text])", name: "never_fulfilled_captures_scope_valid"
    t.check_constraint "captured_cents > 0", name: "never_fulfilled_captures_captured_positive"
    t.check_constraint "char_length(currency::text) = 3", name: "never_fulfilled_captures_currency_length"
    t.check_constraint "code::text = ANY (ARRAY['late_payment_success_after_inventory_release'::character varying::text, 'late_payment_success_after_hold_expiry'::character varying::text, 'pass_all_included_nights_cancelled'::character varying::text, 'unfulfilled_second_capture'::character varying::text, 'event_not_eligible'::character varying::text])", name: "never_fulfilled_captures_code_valid"
    t.check_constraint "proceeds_cents >= 0 AND fee_cents >= 0 AND organizer_fee_cents >= 0 AND tax_cents >= 0", name: "never_fulfilled_captures_components_nonnegative"
    t.check_constraint "provenance::text = 'lifecycle'::text OR provenance_evidence <> '{}'::jsonb", name: "never_fulfilled_captures_backfill_evidence"
    t.check_constraint "provenance::text = ANY (ARRAY['lifecycle'::character varying::text, 'backfill'::character varying::text])", name: "never_fulfilled_captures_provenance_valid"
  end

  create_table "order_items", force: :cascade do |t|
    t.bigint "catalog_item_id"
    t.datetime "created_at", null: false
    t.string "currency", default: "usd", null: false
    t.integer "discount_cents", default: 0, null: false
    t.integer "fee_cents", default: 0, null: false
    t.integer "item_kind", default: 0, null: false
    t.string "name", null: false
    t.bigint "order_id", null: false
    t.integer "organizer_fee_cents", default: 0, null: false
    t.integer "organizer_proceeds_cents", null: false
    t.bigint "pricing_tier_id"
    t.integer "quantity", null: false
    t.integer "subtotal_cents", null: false
    t.integer "tax_cents", default: 0, null: false
    t.bigint "ticket_type_id"
    t.string "tier_name"
    t.integer "unit_price_cents", null: false
    t.datetime "updated_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.index ["catalog_item_id"], name: "index_order_items_on_catalog_item_id"
    t.index ["order_id"], name: "index_order_items_on_order_id"
    t.index ["pricing_tier_id"], name: "index_order_items_on_pricing_tier_id"
    t.index ["ticket_type_id"], name: "index_order_items_on_ticket_type_id"
    t.check_constraint "char_length(currency::text) = 3", name: "order_items_currency_length"
    t.check_constraint "discount_cents >= 0", name: "order_items_discount_nonnegative"
    t.check_constraint "fee_cents >= 0", name: "order_items_fee_nonnegative"
    t.check_constraint "item_kind = 0 AND ticket_type_id IS NOT NULL AND catalog_item_id IS NULL OR item_kind <> 0 AND ticket_type_id IS NULL AND catalog_item_id IS NOT NULL", name: "order_items_catalog_or_ticket"
    t.check_constraint "item_kind = ANY (ARRAY[0, 1, 2, 3, 4])", name: "order_items_kind_valid"
    t.check_constraint "organizer_fee_cents >= 0", name: "order_items_organizer_fee_nonnegative"
    t.check_constraint "organizer_proceeds_cents <= subtotal_cents", name: "order_items_proceeds_within_subtotal"
    t.check_constraint "organizer_proceeds_cents >= 0", name: "order_items_proceeds_nonnegative"
    t.check_constraint "quantity > 0", name: "order_items_quantity_positive"
    t.check_constraint "subtotal_cents >= 0", name: "order_items_subtotal_nonnegative"
    t.check_constraint "tax_cents >= 0", name: "order_items_tax_nonnegative"
    t.check_constraint "unit_price_cents >= 0", name: "order_items_unit_price_nonnegative"
  end

  create_table "orders", force: :cascade do |t|
    t.string "buyer_email"
    t.integer "buyer_fee_percent_snapshot", default: 100, null: false
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
    t.integer "fee_policy_snapshot", default: 0, null: false
    t.datetime "guest_access_expires_at"
    t.datetime "guest_access_revoked_at"
    t.integer "guest_access_version", default: 1, null: false
    t.integer "organizer_fee_cents", default: 0, null: false
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
    t.string "cash_sale_key"
    t.string "cash_sale_request_digest"
    t.string "checkout_key_digest"
    t.string "checkout_request_digest"
    t.datetime "checkout_recovery_expires_at"
    t.string "processing_fee_bearer_snapshot"
    t.string "locale", default: "en", null: false
    t.boolean "marketing_opt_in", default: false, null: false
    t.datetime "retention_anonymized_at"
    t.string "checkout_ip_digest"
    t.bigint "sold_by_id"
    t.datetime "platform_opt_in_at"
    t.datetime "never_fulfilled_at"
    t.bigint "fulfilled_by_payment_id"
    t.index "lower((buyer_email)::text), event_id, created_at DESC, id DESC", name: "index_orders_on_event_and_consent_email"
    t.index "lower(btrim((buyer_email)::text))", name: "index_orders_on_normalized_guest_buyer_email", where: "(user_id IS NULL)"
    t.index ["cash_sale_key"], name: "index_orders_on_cash_sale_key", unique: true
    t.index ["checkout_key_digest"], name: "index_orders_on_checkout_key_digest", unique: true
    t.index ["event_id", "checkout_ip_digest"], name: "index_orders_on_event_id_and_checkout_ip_digest", where: "(checkout_ip_digest IS NOT NULL)"
    t.index ["event_id"], name: "index_orders_on_event_id"
    t.index ["fulfilled_by_payment_id"], name: "index_orders_on_fulfilled_by_payment_id", where: "(fulfilled_by_payment_id IS NOT NULL)"
    t.index ["payment_method"], name: "index_orders_on_payment_method"
    t.index ["promo_code_id"], name: "index_orders_on_promo_code_id"
    t.index ["reference"], name: "index_orders_on_reference", unique: true
    t.index ["retention_anonymized_at"], name: "index_orders_on_retention_anonymized_at"
    t.index ["sold_by_id"], name: "index_orders_on_sold_by_id"
    t.index ["source"], name: "index_orders_on_source"
    t.index ["stripe_payment_intent_id"], name: "index_orders_on_unique_payment_intent", unique: true, where: "(stripe_payment_intent_id IS NOT NULL)"
    t.index ["user_id"], name: "index_orders_on_user_id"
    t.check_constraint "buyer_fee_percent_snapshot >= 0 AND buyer_fee_percent_snapshot <= 100", name: "orders_buyer_fee_percent_snapshot_valid"
    t.check_constraint "char_length(currency::text) = 3", name: "orders_currency_length"
    t.check_constraint "discount_cents <= (subtotal_cents + service_fee_cents)", name: "orders_discount_within_charge"
    t.check_constraint "discount_cents >= 0", name: "orders_discount_nonnegative"
    t.check_constraint "fee_policy_snapshot = ANY (ARRAY[0, 1, 2])", name: "orders_fee_policy_snapshot_valid"
    t.check_constraint "guest_access_version > 0", name: "orders_guest_access_version_positive"
    t.check_constraint "never_fulfilled_at IS NULL OR completed_at IS NULL AND (status <> ALL (ARRAY[0, 1]))", name: "orders_never_fulfilled_not_completed"
    t.check_constraint "never_fulfilled_at IS NULL OR fulfilled_by_payment_id IS NULL", name: "orders_fulfilled_xor_never_fulfilled"
    t.check_constraint "organizer_fee_cents >= 0", name: "orders_organizer_fee_nonnegative"
    t.check_constraint "processing_fee_bearer_snapshot IS NULL OR (processing_fee_bearer_snapshot::text = ANY (ARRAY['platform'::character varying::text, 'organizer'::character varying::text]))", name: "orders_processing_fee_bearer_snapshot_valid"
    t.check_constraint "refund_amount_cents <= total_cents", name: "orders_refund_within_total"
    t.check_constraint "refund_amount_cents >= 0", name: "orders_refund_nonnegative"
    t.check_constraint "service_fee_cents >= 0", name: "orders_service_fee_nonnegative"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2, 3, 4, 5])", name: "orders_status_valid"
    t.check_constraint "subtotal_cents >= 0", name: "orders_subtotal_nonnegative"
    t.check_constraint "total_cents = GREATEST(subtotal_cents + service_fee_cents - discount_cents, 0)", name: "orders_total_matches_components"
    t.check_constraint "total_cents >= 0", name: "orders_total_nonnegative"
  end

  create_table "organization_invitation_dispatches", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.bigint "actor_user_id", null: false
    t.string "recipient", null: false
    t.datetime "created_at", null: false
    t.index ["actor_user_id", "created_at"], name: "index_invitation_dispatches_actor_time"
    t.index ["actor_user_id"], name: "index_organization_invitation_dispatches_on_actor_user_id"
    t.index ["organization_id", "created_at"], name: "index_invitation_dispatches_org_time"
    t.index ["organization_id", "recipient", "created_at"], name: "index_invitation_dispatches_recipient_time"
    t.index ["organization_id"], name: "index_organization_invitation_dispatches_on_organization_id"
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
    t.datetime "invitation_expires_at"
    t.jsonb "pending_event_assignments", default: [], null: false
    t.index "organization_id, lower((invited_email)::text)", name: "idx_organization_memberships_unique_invite", unique: true, where: "((invited_email IS NOT NULL) AND (status = 0))"
    t.index ["invited_by_user_id"], name: "index_organization_memberships_on_invited_by_user_id"
    t.index ["organization_id", "user_id"], name: "idx_organization_memberships_unique_user", unique: true, where: "(user_id IS NOT NULL)"
    t.index ["organization_id"], name: "index_organization_memberships_on_organization_id"
    t.index ["user_id"], name: "index_organization_memberships_on_user_id"
    t.check_constraint "invitation_version > 0", name: "organization_memberships_invitation_version_positive"
    t.check_constraint "jsonb_typeof(pending_event_assignments) = 'array'::text", name: "organization_memberships_pending_event_assignments_array"
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
    t.text "marketing_mailing_address"
    t.datetime "marketing_address_certified_at"
    t.bigint "payout_connected_account_id"
    t.index ["payout_connected_account_id"], name: "index_organizations_on_payout_connected_account_id"
    t.index ["slug"], name: "index_organizations_on_slug", unique: true
    t.check_constraint "char_length(currency::text) = 3", name: "organizations_currency_length"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2])", name: "organizations_status_valid"
  end

  create_table "organizer_follows", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "organization_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.datetime "email_opted_in_at"
    t.string "email_consent_version"
    t.string "email_opted_in_address"
    t.index ["organization_id"], name: "index_organizer_follows_on_organization_id"
    t.index ["user_id", "organization_id"], name: "index_organizer_follows_on_user_id_and_organization_id", unique: true
    t.index ["user_id"], name: "index_organizer_follows_on_user_id"
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
    t.bigint "user_id"
    t.text "verification_notes"
    t.datetime "verification_requested_at"
    t.integer "verification_status", default: 0, null: false
    t.datetime "verified_at"
    t.bigint "verified_by_user_id"
    t.string "verification_phone"
    t.string "verification_link"
    t.text "verification_request_note"
    t.integer "verification_request_version", default: 0, null: false
    t.jsonb "verification_change_diff", default: {}, null: false
    t.index ["organization_id"], name: "index_organizer_profiles_on_organization_id", unique: true
    t.index ["user_id"], name: "index_organizer_profiles_on_user_id", unique: true
    t.index ["verification_status"], name: "index_organizer_profiles_on_verification_status"
    t.index ["verified_by_user_id"], name: "index_organizer_profiles_on_verified_by_user_id"
  end

  create_table "organizer_sales_export_requests", force: :cascade do |t|
    t.bigint "event_id", null: false
    t.bigint "actor_user_id", null: false
    t.jsonb "filters", default: {}, null: false
    t.jsonb "columns", default: [], null: false
    t.integer "row_count", default: 0, null: false
    t.string "status", default: "pending", null: false
    t.string "storage_key"
    t.datetime "expires_at"
    t.datetime "claimed_at"
    t.string "failure_reason"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_user_id", "created_at"], name: "index_sales_exports_on_actor_and_created_at"
    t.index ["actor_user_id"], name: "index_organizer_sales_export_requests_on_actor_user_id"
    t.index ["event_id"], name: "index_organizer_sales_export_requests_on_event_id"
    t.index ["storage_key"], name: "index_sales_exports_on_storage_key"
    t.check_constraint "row_count >= 0", name: "organizer_sales_export_requests_row_count_nonnegative"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'processing'::character varying::text, 'ready'::character varying::text, 'failed'::character varying::text, 'expired'::character varying::text])", name: "organizer_sales_export_requests_status_valid"
  end

  create_table "organizer_tax_informations", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.string "legal_name", null: false
    t.string "business_name"
    t.string "tax_classification", null: false
    t.string "tin_type", null: false
    t.text "tin", null: false
    t.string "tin_last_four", limit: 4, null: false
    t.text "mailing_address", null: false
    t.string "exempt_payee_code"
    t.string "signer_name", null: false
    t.datetime "certified_at", null: false
    t.string "certification_version", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "retention_anonymized_at"
    t.string "tin_match_status", default: "unverified", null: false
    t.integer "tin_match_result_code"
    t.datetime "tin_matched_at"
    t.string "b_notice_stage"
    t.datetime "b_notice_sent_at"
    t.date "b_notice_response_due_on"
    t.boolean "backup_withholding_flag", default: false, null: false
    t.text "backup_withholding_reason"
    t.date "irs_notice_received_on"
    t.date "b_notice_send_due_on"
    t.date "first_b_notice_received_on"
    t.string "irs_validation_evidence_type"
    t.date "irs_validation_recorded_on"
    t.bigint "irs_validation_admin_id"
    t.string "irs_validation_document_reference"
    t.string "tin_digest"
    t.string "validation_identity_digest"
    t.string "tin_match_identity_digest"
    t.string "b_notice_identity_digest"
    t.index ["organization_id"], name: "index_organizer_tax_informations_on_organization_id", unique: true
    t.index ["retention_anonymized_at"], name: "index_organizer_tax_informations_on_retention_anonymized_at"
    t.index ["tin_digest"], name: "index_organizer_tax_informations_on_tin_digest"
    t.check_constraint "tin_match_status::text = ANY (ARRAY['unverified'::character varying::text, 'matched'::character varying::text, 'missing_or_invalid'::character varying::text, 'not_issued'::character varying::text, 'mismatch'::character varying::text, 'invalid_request'::character varying::text, 'duplicate'::character varying::text, 'matched_ssn'::character varying::text, 'matched_ein'::character varying::text, 'matched_both'::character varying::text])", name: "tax_information_tin_match_status_valid"
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
    t.datetime "retention_anonymized_at"
    t.index ["payment_id"], name: "index_payment_events_on_payment_id"
    t.index ["retention_anonymized_at"], name: "index_payment_events_on_retention_anonymized_at"
    t.index ["webhook_event_id"], name: "index_payment_events_on_webhook_event_id", unique: true
    t.check_constraint "amount_cents IS NULL OR amount_cents >= 0", name: "payment_events_amount_nonnegative"
    t.check_constraint "currency IS NULL OR char_length(currency::text) = 3", name: "payment_events_currency_length"
  end

  create_table "payment_readiness_reviews", force: :cascade do |t|
    t.bigint "actor_user_id", null: false
    t.bigint "connected_account_id", null: false
    t.jsonb "controls", default: {}, null: false
    t.datetime "created_at", null: false
    t.integer "decision", null: false
    t.datetime "effective_at", null: false
    t.string "evidence_digest", null: false
    t.string "evidence_reference", null: false
    t.datetime "expires_at", null: false
    t.string "fee_tax_schedule_reference", null: false
    t.string "liability_schedule_reference", null: false
    t.string "merchant_of_record", null: false
    t.bigint "parent_review_id"
    t.string "provider_approval_reference", null: false
    t.string "provider_state_digest", null: false
    t.text "reason"
    t.datetime "updated_at", null: false
    t.string "review_kind", default: "provider_evidence", null: false
    t.jsonb "reviewed_snapshot", default: {}, null: false
    t.index ["actor_user_id"], name: "index_payment_readiness_reviews_on_actor_user_id"
    t.index ["connected_account_id", "created_at"], name: "idx_payment_reviews_account_timeline"
    t.index ["connected_account_id"], name: "index_payment_readiness_reviews_on_connected_account_id"
    t.index ["parent_review_id"], name: "idx_payment_reviews_one_approval", unique: true, where: "((parent_review_id IS NOT NULL) AND (decision = 1))"
    t.index ["parent_review_id"], name: "idx_payment_reviews_one_rejection", unique: true, where: "((parent_review_id IS NOT NULL) AND (decision = 3))"
    t.index ["parent_review_id"], name: "idx_payment_reviews_one_revocation", unique: true, where: "((parent_review_id IS NOT NULL) AND (decision = 2))"
    t.index ["parent_review_id"], name: "index_payment_readiness_reviews_on_parent_review_id"
    t.check_constraint "decision = 0 AND parent_review_id IS NULL OR (decision = ANY (ARRAY[1, 2, 3])) AND parent_review_id IS NOT NULL", name: "payment_readiness_reviews_parent_valid"
    t.check_constraint "decision = ANY (ARRAY[0, 1, 2, 3])", name: "payment_readiness_reviews_decision_valid"
    t.check_constraint "evidence_digest::text ~ '^[0-9a-f]{64}$'::text", name: "payment_readiness_reviews_digest_valid"
    t.check_constraint "expires_at > effective_at", name: "payment_readiness_reviews_window_valid"
    t.check_constraint "merchant_of_record::text = ANY (ARRAY['platform'::character varying::text, 'organizer'::character varying::text, 'provider_managed'::character varying::text])", name: "payment_readiness_reviews_merchant_valid"
    t.check_constraint "provider_state_digest::text ~ '^[0-9a-f]{64}$'::text", name: "payment_readiness_reviews_provider_state_digest_valid"
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
    t.string "provider_environment"
    t.string "provider_account_id"
    t.string "provider_platform_account_id"
    t.datetime "retention_anonymized_at"
    t.string "stripe_checkout_session_id"
    t.text "stripe_checkout_url"
    t.datetime "capture_recorded_at"
    t.index ["id", "order_id"], name: "index_payments_on_id_and_order_id", unique: true
    t.index ["idempotency_key"], name: "index_payments_on_idempotency_key", unique: true
    t.index ["order_id"], name: "index_payments_on_order_id"
    t.index ["provider", "provider_payment_id"], name: "index_payments_on_unique_provider_payment", unique: true, where: "(provider_payment_id IS NOT NULL)"
    t.index ["retention_anonymized_at"], name: "index_payments_on_retention_anonymized_at"
    t.index ["stripe_checkout_session_id"], name: "index_payments_on_stripe_checkout_session_id", unique: true, where: "(stripe_checkout_session_id IS NOT NULL)"
    t.check_constraint "amount_cents >= 0", name: "payments_amount_nonnegative"
    t.check_constraint "char_length(currency::text) = 3", name: "payments_currency_length"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2, 3, 4, 5])", name: "payments_status_valid"
  end

  create_table "payout_check_adjustments", force: :cascade do |t|
    t.bigint "payout_id", null: false
    t.bigint "created_by_user_id", null: false
    t.integer "amount_cents", null: false
    t.text "reason", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_user_id"], name: "index_payout_check_adjustments_on_created_by_user_id"
    t.index ["payout_id"], name: "index_payout_check_adjustments_on_payout_id"
    t.check_constraint "amount_cents <> 0", name: "payout_check_adjustments_nonzero"
  end

  create_table "payout_custody_determinations", force: :cascade do |t|
    t.bigint "payout_id", null: false
    t.bigint "settlement_id", null: false
    t.string "determination", null: false
    t.string "basis", null: false
    t.bigint "funded_order_item_ids", default: [], null: false, array: true
    t.bigint "qualifying_payment_ids", default: [], null: false, array: true
    t.boolean "conservative_inclusion", null: false
    t.jsonb "evidence", default: {}, null: false
    t.datetime "determined_at", null: false
    t.index ["payout_id"], name: "index_payout_custody_determinations_on_payout_id", unique: true
    t.index ["settlement_id"], name: "index_payout_custody_determinations_on_settlement_id"
    t.check_constraint "basis::text = ANY (ARRAY['recorded_at_paid'::character varying::text, 'derived_history'::character varying::text])", name: "payout_custody_determinations_basis_valid"
    t.check_constraint "determination::text = ANY (ARRAY['stripe_custody'::character varying::text, 'non_custodial'::character varying::text, 'ambiguous'::character varying::text])", name: "payout_custody_determinations_determination_valid"
    t.check_constraint "jsonb_typeof(evidence) = 'object'::text", name: "payout_custody_determinations_evidence_object"
  end

  create_table "payout_line_allocations", force: :cascade do |t|
    t.bigint "payout_id", null: false
    t.bigint "order_item_id", null: false
    t.integer "amount_cents", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["order_item_id"], name: "index_payout_line_allocations_on_order_item_id"
    t.index ["payout_id", "order_item_id"], name: "index_payout_line_allocations_on_payout_id_and_order_item_id", unique: true
    t.index ["payout_id"], name: "index_payout_line_allocations_on_payout_id"
    t.check_constraint "amount_cents >= 0", name: "payout_line_allocations_nonnegative"
  end

  create_table "payout_return_proofs", force: :cascade do |t|
    t.bigint "payout_id", null: false
    t.string "kind", null: false
    t.bigint "returned_amount_cents", null: false
    t.datetime "returned_at", null: false
    t.datetime "sent_at", null: false
    t.string "return_reference_digest", null: false
    t.datetime "recorded_at", null: false
    t.index ["payout_id"], name: "index_payout_return_proofs_on_payout_id", unique: true
    t.index ["return_reference_digest"], name: "index_payout_return_proofs_on_return_reference_digest", unique: true
    t.check_constraint "kind::text = ANY (ARRAY['verified_return'::character varying::text, 'accepted_transfer_return'::character varying::text, 'attached_return'::character varying::text])", name: "payout_return_proofs_kind_valid"
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
    t.jsonb "payee_snapshot", default: {}, null: false
    t.string "payee_approval_digest"
    t.jsonb "tax_information_snapshot", default: {}, null: false
    t.text "tax_information_tin"
    t.string "tax_approval_digest"
    t.string "held_from_status"
    t.datetime "retention_anonymized_at"
    t.integer "withheld_cents", default: 0, null: false
    t.integer "withholding_rate_bps", default: 0, null: false
    t.string "withholding_reason"
    t.text "withholding_override_reason"
    t.integer "under_withheld_cents", default: 0, null: false
    t.integer "carried_withholding_cents", default: 0, null: false
    t.datetime "provider_accepted_at"
    t.string "provider_accepted_basis"
    t.datetime "accepted_transfer_recorded_at"
    t.index ["connected_account_id"], name: "index_payouts_on_connected_account_id"
    t.index ["event_id"], name: "index_payouts_on_event_id"
    t.index ["idempotency_key"], name: "index_payouts_on_idempotency_key", unique: true
    t.index ["organization_id"], name: "index_payouts_on_organization_id"
    t.index ["provider", "provider_payout_id"], name: "idx_payouts_unique_provider_id", unique: true, where: "(provider_payout_id IS NOT NULL)"
    t.index ["retention_anonymized_at"], name: "index_payouts_on_retention_anonymized_at"
    t.index ["settlement_id"], name: "index_payouts_on_settlement_id"
    t.check_constraint "(provider_accepted_basis::text = ANY (ARRAY['provider_reported'::character varying::text, 'locally_observed'::character varying::text])) AND provider_accepted_at IS NOT NULL OR provider_accepted_basis IS NULL AND provider_accepted_at IS NULL", name: "payouts_provider_accepted_basis_valid"
    t.check_constraint "(withheld_cents + carried_withholding_cents) <= amount_cents", name: "payouts_total_withholding_within_gross"
    t.check_constraint "amount_cents > 0", name: "payouts_amount_positive"
    t.check_constraint "carried_withholding_cents >= 0", name: "payouts_carried_withholding_nonnegative"
    t.check_constraint "char_length(currency::text) = 3", name: "payouts_currency_length"
    t.check_constraint "jsonb_typeof(payee_snapshot) = 'object'::text", name: "payouts_payee_snapshot_object"
    t.check_constraint "jsonb_typeof(tax_information_snapshot) = 'object'::text", name: "payouts_tax_snapshot_object"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2, 3, 4, 5])", name: "payouts_status_valid"
    t.check_constraint "under_withheld_cents >= 0", name: "payouts_under_withheld_nonnegative"
    t.check_constraint "withheld_cents >= 0 AND withheld_cents < amount_cents", name: "payouts_withholding_valid"
  end

  create_table "pilot_closeout_reviews", force: :cascade do |t|
    t.bigint "actor_user_id", null: false
    t.string "application_revision", null: false
    t.jsonb "cleanup_results", default: {}, null: false
    t.datetime "created_at", null: false
    t.integer "decision", null: false
    t.bigint "event_id", null: false
    t.string "evidence_digest", null: false
    t.string "evidence_reference", null: false
    t.jsonb "evidence_references", default: {}, null: false
    t.integer "expansion_decision", null: false
    t.jsonb "expansion_scope", default: {}, null: false
    t.bigint "live_pilot_run_id", null: false
    t.jsonb "local_metrics", default: {}, null: false
    t.string "local_state_digest", null: false
    t.jsonb "outcome_metrics", default: {}, null: false
    t.bigint "parent_review_id"
    t.text "reason"
    t.jsonb "reconciliation_results", default: {}, null: false
    t.jsonb "retrospective_actions", default: [], null: false
    t.datetime "signed_at", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_user_id"], name: "index_pilot_closeout_reviews_on_actor_user_id"
    t.index ["event_id", "created_at"], name: "idx_pilot_closeout_timeline"
    t.index ["event_id"], name: "index_pilot_closeout_reviews_on_event_id"
    t.index ["live_pilot_run_id", "created_at"], name: "idx_pilot_closeout_run_timeline"
    t.index ["live_pilot_run_id"], name: "index_pilot_closeout_reviews_on_live_pilot_run_id"
    t.index ["parent_review_id"], name: "idx_pilot_closeout_one_approval", unique: true, where: "((parent_review_id IS NOT NULL) AND (decision = 1))"
    t.index ["parent_review_id"], name: "idx_pilot_closeout_one_rejection", unique: true, where: "((parent_review_id IS NOT NULL) AND (decision = 3))"
    t.index ["parent_review_id"], name: "idx_pilot_closeout_one_revocation", unique: true, where: "((parent_review_id IS NOT NULL) AND (decision = 2))"
    t.index ["parent_review_id"], name: "index_pilot_closeout_reviews_on_parent_review_id"
    t.check_constraint "decision = 0 AND parent_review_id IS NULL OR (decision = ANY (ARRAY[1, 2, 3])) AND parent_review_id IS NOT NULL", name: "pilot_closeout_parent_valid"
    t.check_constraint "decision = ANY (ARRAY[0, 1, 2, 3])", name: "pilot_closeout_decision_valid"
    t.check_constraint "evidence_digest::text ~ '^[0-9a-f]{64}$'::text AND local_state_digest::text ~ '^[0-9a-f]{64}$'::text", name: "pilot_closeout_digests_valid"
    t.check_constraint "expansion_decision = ANY (ARRAY[0, 1, 2])", name: "pilot_closeout_expansion_valid"
  end

  create_table "pilot_readiness_reviews", force: :cascade do |t|
    t.bigint "actor_user_id", null: false
    t.string "application_revision", null: false
    t.jsonb "assignments", default: {}, null: false
    t.jsonb "controls", default: {}, null: false
    t.datetime "created_at", null: false
    t.integer "decision", null: false
    t.datetime "effective_at", null: false
    t.bigint "event_id", null: false
    t.string "event_state_digest", null: false
    t.string "evidence_digest", null: false
    t.string "evidence_reference", null: false
    t.datetime "expires_at", null: false
    t.bigint "parent_review_id"
    t.text "reason"
    t.datetime "updated_at", null: false
    t.index ["actor_user_id"], name: "index_pilot_readiness_reviews_on_actor_user_id"
    t.index ["event_id", "created_at"], name: "idx_pilot_readiness_reviews_timeline"
    t.index ["event_id"], name: "index_pilot_readiness_reviews_on_event_id"
    t.index ["parent_review_id"], name: "idx_pilot_readiness_reviews_one_decision", unique: true, where: "((parent_review_id IS NOT NULL) AND (decision = ANY (ARRAY[1, 3])))"
    t.index ["parent_review_id"], name: "idx_pilot_readiness_reviews_one_revocation", unique: true, where: "((parent_review_id IS NOT NULL) AND (decision = 2))"
    t.index ["parent_review_id"], name: "index_pilot_readiness_reviews_on_parent_review_id"
    t.check_constraint "decision = 0 AND parent_review_id IS NULL OR (decision = ANY (ARRAY[1, 2, 3])) AND parent_review_id IS NOT NULL", name: "pilot_readiness_reviews_parent_valid"
    t.check_constraint "decision = ANY (ARRAY[0, 1, 2, 3])", name: "pilot_readiness_reviews_decision_valid"
    t.check_constraint "evidence_digest::text ~ '^[0-9a-f]{64}$'::text AND event_state_digest::text ~ '^[0-9a-f]{64}$'::text", name: "pilot_readiness_reviews_digests_valid"
    t.check_constraint "expires_at > effective_at", name: "pilot_readiness_reviews_window_valid"
  end

  create_table "pilot_validation_reviews", force: :cascade do |t|
    t.jsonb "accessibility_results", default: {}, null: false
    t.bigint "actor_user_id", null: false
    t.string "application_revision", null: false
    t.jsonb "buyer_flows", default: {}, null: false
    t.jsonb "controls", default: {}, null: false
    t.datetime "created_at", null: false
    t.integer "decision", null: false
    t.jsonb "device_matrix", default: {}, null: false
    t.datetime "effective_at", null: false
    t.bigint "event_id", null: false
    t.string "event_state_digest", null: false
    t.string "evidence_digest", null: false
    t.string "evidence_reference", null: false
    t.datetime "expires_at", null: false
    t.jsonb "load_results", default: {}, null: false
    t.jsonb "organizer_flows", default: {}, null: false
    t.bigint "parent_review_id"
    t.bigint "pilot_readiness_review_id", null: false
    t.text "reason"
    t.datetime "updated_at", null: false
    t.index ["actor_user_id"], name: "index_pilot_validation_reviews_on_actor_user_id"
    t.index ["event_id", "created_at"], name: "idx_pilot_validation_reviews_timeline"
    t.index ["event_id"], name: "index_pilot_validation_reviews_on_event_id"
    t.index ["parent_review_id"], name: "idx_pilot_validation_reviews_one_decision", unique: true, where: "((parent_review_id IS NOT NULL) AND (decision = ANY (ARRAY[1, 3])))"
    t.index ["parent_review_id"], name: "idx_pilot_validation_reviews_one_revocation", unique: true, where: "((parent_review_id IS NOT NULL) AND (decision = 2))"
    t.index ["parent_review_id"], name: "index_pilot_validation_reviews_on_parent_review_id"
    t.index ["pilot_readiness_review_id"], name: "index_pilot_validation_reviews_on_pilot_readiness_review_id"
    t.check_constraint "decision = 0 AND parent_review_id IS NULL OR (decision = ANY (ARRAY[1, 2, 3])) AND parent_review_id IS NOT NULL", name: "pilot_validation_reviews_parent_valid"
    t.check_constraint "decision = ANY (ARRAY[0, 1, 2, 3])", name: "pilot_validation_reviews_decision_valid"
    t.check_constraint "evidence_digest::text ~ '^[0-9a-f]{64}$'::text AND event_state_digest::text ~ '^[0-9a-f]{64}$'::text", name: "pilot_validation_reviews_digests_valid"
    t.check_constraint "expires_at > effective_at", name: "pilot_validation_reviews_window_valid"
  end

  create_table "platform_capability_reviews", force: :cascade do |t|
    t.bigint "actor_user_id", null: false
    t.string "capability", null: false
    t.string "configuration_digest", null: false
    t.jsonb "controls", default: {}, null: false
    t.datetime "created_at", null: false
    t.integer "decision", null: false
    t.datetime "effective_at", null: false
    t.string "evidence_digest", null: false
    t.string "evidence_reference", null: false
    t.datetime "expires_at", null: false
    t.bigint "parent_review_id"
    t.text "reason"
    t.datetime "updated_at", null: false
    t.index ["actor_user_id"], name: "index_platform_capability_reviews_on_actor_user_id"
    t.index ["capability", "created_at"], name: "idx_platform_capability_reviews_timeline"
    t.index ["parent_review_id"], name: "idx_platform_capability_reviews_one_approval", unique: true, where: "((parent_review_id IS NOT NULL) AND (decision = 1))"
    t.index ["parent_review_id"], name: "idx_platform_capability_reviews_one_rejection", unique: true, where: "((parent_review_id IS NOT NULL) AND (decision = 3))"
    t.index ["parent_review_id"], name: "idx_platform_capability_reviews_one_revocation", unique: true, where: "((parent_review_id IS NOT NULL) AND (decision = 2))"
    t.index ["parent_review_id"], name: "index_platform_capability_reviews_on_parent_review_id"
    t.check_constraint "capability::text = ANY (ARRAY['stripe_live'::character varying::text, 'resend_production'::character varying::text, 'apple_wallet'::character varying::text, 'google_wallet'::character varying::text, 'clover_card_present'::character varying::text, 'policy_register'::character varying::text])", name: "platform_capability_reviews_capability_valid"
    t.check_constraint "decision = 0 AND parent_review_id IS NULL OR (decision = ANY (ARRAY[1, 2, 3])) AND parent_review_id IS NOT NULL", name: "platform_capability_reviews_parent_valid"
    t.check_constraint "decision = ANY (ARRAY[0, 1, 2, 3])", name: "platform_capability_reviews_decision_valid"
    t.check_constraint "evidence_digest::text ~ '^[0-9a-f]{64}$'::text AND configuration_digest::text ~ '^[0-9a-f]{64}$'::text", name: "platform_capability_reviews_digests_valid"
    t.check_constraint "expires_at > effective_at", name: "platform_capability_reviews_window_valid"
  end

  create_table "platform_invitations", force: :cascade do |t|
    t.string "email", null: false
    t.integer "role", null: false
    t.integer "status", default: 0, null: false
    t.integer "invitation_version", default: 1, null: false
    t.datetime "invited_at", null: false
    t.datetime "expires_at", null: false
    t.datetime "accepted_at"
    t.datetime "revoked_at"
    t.bigint "invited_by_user_id", null: false
    t.bigint "accepted_by_user_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index "lower((email)::text)", name: "idx_platform_invitations_unique_pending_email", unique: true, where: "(status = 0)"
    t.index ["accepted_by_user_id"], name: "index_platform_invitations_on_accepted_by_user_id"
    t.index ["invited_by_user_id"], name: "index_platform_invitations_on_invited_by_user_id"
    t.check_constraint "invitation_version > 0", name: "platform_invitations_version_positive"
    t.check_constraint "role = ANY (ARRAY[2, 3])", name: "platform_invitations_staff_role"
    t.check_constraint "status <> 1 OR accepted_at IS NOT NULL AND accepted_by_user_id IS NOT NULL", name: "platform_invitations_acceptance_recorded"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2])", name: "platform_invitations_status_valid"
  end

  create_table "platform_subscribers", force: :cascade do |t|
    t.string "email", null: false
    t.string "name"
    t.string "status", default: "pending", null: false
    t.string "source", null: false
    t.jsonb "interests", default: [], null: false
    t.jsonb "villages", default: [], null: false
    t.string "confirmation_nonce", null: false
    t.datetime "confirmed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_platform_subscribers_on_email", unique: true
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

  create_table "privacy_email_suppressions", force: :cascade do |t|
    t.string "email_digest", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email_digest"], name: "index_privacy_email_suppressions_on_email_digest", unique: true
  end

  create_table "privacy_requests", force: :cascade do |t|
    t.string "guest_challenge_digest"
    t.datetime "guest_challenge_expires_at"
    t.integer "guest_challenge_attempts", default: 0, null: false
    t.datetime "guest_challenge_passed_at"
    t.string "kind", null: false
    t.string "status", default: "submitted", null: false
    t.bigint "user_id"
    t.bigint "order_id"
    t.string "requester_email", null: false
    t.bigint "verified_by_id"
    t.datetime "verified_at"
    t.bigint "executed_by_id"
    t.datetime "executed_at"
    t.jsonb "result", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "retention_anonymized_at"
    t.jsonb "verified_emails", default: [], null: false
    t.index ["executed_by_id"], name: "index_privacy_requests_on_executed_by_id"
    t.index ["order_id"], name: "index_privacy_requests_on_order_id"
    t.index ["retention_anonymized_at"], name: "index_privacy_requests_on_retention_anonymized_at"
    t.index ["status", "created_at"], name: "index_privacy_requests_on_status_and_created_at"
    t.index ["user_id"], name: "index_privacy_requests_on_user_id"
    t.index ["verified_by_id"], name: "index_privacy_requests_on_verified_by_id"
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

  create_table "promoter_commission_entries", force: :cascade do |t|
    t.integer "amount_cents", null: false
    t.datetime "created_at", null: false
    t.string "currency", default: "usd", null: false
    t.string "idempotency_key", null: false
    t.integer "kind", null: false
    t.datetime "occurred_at", null: false
    t.bigint "order_id", null: false
    t.bigint "promoter_id", null: false
    t.bigint "refund_id"
    t.datetime "updated_at", null: false
    t.index ["idempotency_key"], name: "index_promoter_commission_entries_idempotency", unique: true
    t.index ["order_id"], name: "index_promoter_commission_entries_on_order_id"
    t.index ["promoter_id"], name: "index_promoter_commission_entries_on_promoter_id"
    t.index ["refund_id"], name: "index_promoter_commission_entries_on_refund_id"
    t.check_constraint "amount_cents <> 0", name: "promoter_commission_entries_amount_nonzero"
    t.check_constraint "kind = ANY (ARRAY[0, 1, 2])", name: "promoter_commission_entries_kind_valid"
  end

  create_table "promoters", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "code", null: false
    t.integer "commission_bps", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "email"
    t.bigint "event_id", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["event_id", "code"], name: "index_promoters_on_event_id_and_code", unique: true
    t.index ["event_id"], name: "index_promoters_on_event_id"
    t.check_constraint "commission_bps >= 0 AND commission_bps <= 10000", name: "promoters_commission_valid"
  end

  create_table "public_cache_generations", force: :cascade do |t|
    t.string "name", null: false
    t.bigint "value", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_public_cache_generations_on_name", unique: true
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
    t.datetime "retention_anonymized_at"
    t.datetime "hold_started_at"
    t.datetime "proof_checked_at"
    t.index "((details ->> 'warning_id'::text))", name: "index_reconciliation_exceptions_on_early_fraud_warning_id", unique: true, where: "(((code)::text = 'early_fraud_warning'::text) AND (details ? 'warning_id'::text))"
    t.index ["order_id"], name: "index_reconciliation_exceptions_on_order_id"
    t.index ["payment_id"], name: "index_reconciliation_exceptions_on_payment_id"
    t.index ["retention_anonymized_at"], name: "index_reconciliation_exceptions_on_retention_anonymized_at"
    t.index ["status", "created_at"], name: "index_reconciliation_exceptions_on_status_and_created_at"
    t.index ["webhook_event_id"], name: "index_reconciliation_exceptions_on_webhook_event_id"
    t.check_constraint "status = ANY (ARRAY[0, 1])", name: "reconciliation_exceptions_status_valid"
  end

  create_table "referral_attributions", force: :cascade do |t|
    t.datetime "attributed_at", null: false
    t.string "campaign"
    t.string "code_snapshot", null: false
    t.datetime "created_at", null: false
    t.string "medium"
    t.bigint "order_id", null: false
    t.bigint "promoter_id", null: false
    t.string "source"
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_referral_attributions_on_order_id", unique: true
    t.index ["promoter_id"], name: "index_referral_attributions_on_promoter_id"
  end

  create_table "refund_items", force: :cascade do |t|
    t.integer "amount_cents", null: false
    t.datetime "created_at", null: false
    t.integer "fee_cents", default: 0, null: false
    t.bigint "order_item_id", null: false
    t.integer "organizer_fee_cents", default: 0, null: false
    t.integer "organizer_proceeds_cents", default: 0, null: false
    t.integer "quantity", default: 0, null: false
    t.bigint "refund_id", null: false
    t.integer "tax_cents", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["order_item_id"], name: "index_refund_items_on_order_item_id"
    t.index ["refund_id", "order_item_id"], name: "index_refund_items_on_refund_id_and_order_item_id", unique: true
    t.index ["refund_id"], name: "index_refund_items_on_refund_id"
    t.check_constraint "amount_cents = (organizer_proceeds_cents + fee_cents + organizer_fee_cents + tax_cents)", name: "refund_items_components_match_amount"
    t.check_constraint "amount_cents >= 0", name: "refund_items_amount_nonnegative"
    t.check_constraint "fee_cents >= 0", name: "refund_items_fee_nonnegative"
    t.check_constraint "organizer_fee_cents >= 0", name: "refund_items_organizer_fee_nonnegative"
    t.check_constraint "organizer_proceeds_cents >= 0", name: "refund_items_proceeds_nonnegative"
    t.check_constraint "quantity >= 0", name: "refund_items_quantity_nonnegative"
    t.check_constraint "tax_cents >= 0", name: "refund_items_tax_nonnegative"
  end

  create_table "refund_tickets", force: :cascade do |t|
    t.integer "amount_cents", null: false
    t.datetime "created_at", null: false
    t.bigint "refund_id", null: false
    t.datetime "released_at"
    t.bigint "ticket_id", null: false
    t.datetime "updated_at", null: false
    t.index ["refund_id"], name: "index_refund_tickets_on_refund_id"
    t.index ["ticket_id"], name: "index_refund_tickets_on_ticket_id", unique: true, where: "(released_at IS NULL)"
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
    t.datetime "retention_anonymized_at"
    t.datetime "success_recorded_at"
    t.bigint "repayment_operation_id"
    t.index ["idempotency_key"], name: "index_refunds_on_idempotency_key", unique: true
    t.index ["order_id"], name: "index_refunds_on_order_id"
    t.index ["payment_id"], name: "index_refunds_on_payment_id"
    t.index ["provider", "provider_refund_id"], name: "index_refunds_on_unique_provider_refund", unique: true, where: "(provider_refund_id IS NOT NULL)"
    t.index ["repayment_operation_id"], name: "index_refunds_on_repayment_operation_id", unique: true, where: "(repayment_operation_id IS NOT NULL)"
    t.index ["requested_by_id"], name: "index_refunds_on_requested_by_id"
    t.index ["retention_anonymized_at"], name: "index_refunds_on_retention_anonymized_at"
    t.check_constraint "amount_cents > 0", name: "refunds_amount_positive"
    t.check_constraint "char_length(currency::text) = 3", name: "refunds_currency_length"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2, 3])", name: "refunds_status_valid"
  end

  create_table "registration_questions", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.bigint "event_id", null: false
    t.integer "kind", default: 0, null: false
    t.jsonb "options", default: [], null: false
    t.integer "position", default: 0, null: false
    t.string "prompt", null: false
    t.boolean "required", default: false, null: false
    t.datetime "updated_at", null: false
    t.integer "scope", default: 0, null: false
    t.jsonb "ticket_type_ids", default: [], null: false
    t.boolean "show_on_scanner", default: false, null: false
    t.string "help_text", limit: 250
    t.jsonb "validation_rules", default: {}, null: false
    t.index ["event_id", "active", "position"], name: "idx_on_event_id_active_position_0e532f85bc"
    t.index ["event_id"], name: "index_registration_questions_on_event_id"
    t.check_constraint "jsonb_typeof(ticket_type_ids) = 'array'::text", name: "registration_questions_ticket_type_ids_array"
    t.check_constraint "jsonb_typeof(validation_rules) = 'object'::text", name: "registration_questions_validation_rules_object"
    t.check_constraint "kind = ANY (ARRAY[0, 1, 2, 3, 4, 5, 6, 7])", name: "registration_questions_kind_valid"
    t.check_constraint "scope = ANY (ARRAY[0, 1])", name: "registration_questions_scope_valid"
  end

  create_table "registration_responses", force: :cascade do |t|
    t.jsonb "answer", default: {}, null: false
    t.datetime "answered_at", null: false
    t.datetime "created_at", null: false
    t.integer "kind_snapshot", null: false
    t.jsonb "options_snapshot", default: [], null: false
    t.bigint "order_id", null: false
    t.string "prompt_snapshot", null: false
    t.bigint "registration_question_id", null: false
    t.boolean "required_snapshot", default: false, null: false
    t.datetime "updated_at", null: false
    t.datetime "retention_anonymized_at"
    t.bigint "ticket_id"
    t.index ["order_id", "registration_question_id"], name: "index_registration_responses_unique_order", unique: true, where: "(ticket_id IS NULL)"
    t.index ["order_id"], name: "index_registration_responses_on_order_id"
    t.index ["registration_question_id"], name: "index_registration_responses_on_registration_question_id"
    t.index ["retention_anonymized_at"], name: "index_registration_responses_on_retention_anonymized_at"
    t.index ["ticket_id", "registration_question_id"], name: "index_registration_responses_unique_ticket", unique: true, where: "(ticket_id IS NOT NULL)"
    t.index ["ticket_id"], name: "index_registration_responses_on_ticket_id"
  end

  create_table "repayment_operations", force: :cascade do |t|
    t.bigint "never_fulfilled_capture_id", null: false
    t.bigint "payment_id", null: false
    t.integer "sequence", null: false
    t.integer "amount_cents", null: false
    t.string "currency", null: false
    t.string "idempotency_key", null: false
    t.string "state", default: "reserved", null: false
    t.string "source", null: false
    t.boolean "adopted", default: false, null: false
    t.bigint "refund_id"
    t.integer "submission_count", default: 0, null: false
    t.datetime "last_submitted_at"
    t.string "terminal_reason"
    t.jsonb "evidence", default: {}, null: false
    t.datetime "created_at", default: -> { "timezone('UTC'::text, clock_timestamp())" }, null: false
    t.datetime "updated_at", null: false
    t.index ["idempotency_key"], name: "index_repayment_operations_on_idempotency_key", unique: true
    t.index ["never_fulfilled_capture_id", "sequence"], name: "index_repayment_operations_on_capture_sequence", unique: true
    t.index ["payment_id", "state"], name: "index_repayment_operations_on_payment_id_and_state"
    t.index ["refund_id"], name: "index_repayment_operations_on_refund_id", unique: true
    t.check_constraint "(state::text <> ALL (ARRAY['submitting'::character varying::text, 'unknown'::character varying::text])) OR refund_id IS NOT NULL", name: "repayment_operations_submitted_has_refund"
    t.check_constraint "amount_cents > 0", name: "repayment_operations_amount_positive"
    t.check_constraint "sequence > 0", name: "repayment_operations_sequence_positive"
    t.check_constraint "source::text = ANY (ARRAY['automatic'::character varying::text, 'admin_late_capture'::character varying::text, 'admin_order_refund'::character varying::text, 'fraud_warning'::character varying::text, 'evaluator'::character varying::text, 'queue_retry'::character varying::text, 'adoption'::character varying::text])", name: "repayment_operations_source_valid"
    t.check_constraint "state::text = ANY (ARRAY['reserved'::character varying::text, 'submitting'::character varying::text, 'unknown'::character varying::text, 'succeeded'::character varying::text, 'failed_terminal'::character varying::text])", name: "repayment_operations_state_valid"
    t.check_constraint "submission_count >= 0", name: "repayment_operations_submission_count_nonnegative"
  end

  create_table "runtime_alert_states", primary_key: "signal", id: :string, force: :cascade do |t|
    t.integer "last_count", default: 0, null: false
    t.datetime "last_alerted_at"
    t.datetime "updated_at", null: false
    t.datetime "incident_opened_at"
  end

  create_table "runtime_executions", id: false, force: :cascade do |t|
    t.string "task_key", null: false
    t.string "application_revision", null: false
    t.datetime "last_succeeded_at", null: false
    t.index ["task_key", "application_revision"], name: "index_runtime_executions_on_task_key_and_application_revision", unique: true
  end

  create_table "runtime_throttle_buckets", id: false, force: :cascade do |t|
    t.string "key_hash", limit: 64, null: false
    t.bigint "value", default: 0, null: false
    t.datetime "expires_at", null: false
    t.index ["expires_at"], name: "index_runtime_throttle_buckets_on_expires_at"
    t.index ["key_hash"], name: "index_runtime_throttle_buckets_on_key_hash", unique: true
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

  create_table "seat_audit_events", force: :cascade do |t|
    t.string "action", null: false
    t.bigint "actor_user_id"
    t.datetime "created_at", null: false
    t.bigint "event_id", null: false
    t.bigint "event_seat_id"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "occurred_at", null: false
    t.bigint "seat_hold_session_id"
    t.bigint "ticket_id"
    t.datetime "updated_at", null: false
    t.index ["actor_user_id"], name: "index_seat_audit_events_on_actor_user_id"
    t.index ["event_id", "occurred_at"], name: "index_seat_audit_events_on_event_id_and_occurred_at"
    t.index ["event_id"], name: "index_seat_audit_events_on_event_id"
    t.index ["event_seat_id"], name: "index_seat_audit_events_on_event_seat_id"
    t.index ["seat_hold_session_id"], name: "index_seat_audit_events_on_seat_hold_session_id"
    t.index ["ticket_id"], name: "index_seat_audit_events_on_ticket_id"
  end

  create_table "seat_hold_sessions", force: :cascade do |t|
    t.boolean "accessibility_attested", default: false, null: false
    t.datetime "claimed_at"
    t.datetime "consumed_at"
    t.datetime "created_at", null: false
    t.bigint "event_seating_configuration_id", null: false
    t.datetime "expires_at", null: false
    t.bigint "order_id"
    t.datetime "released_at"
    t.string "source", default: "online", null: false
    t.integer "status", default: 0, null: false
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["event_seating_configuration_id"], name: "index_seat_hold_sessions_on_configuration_id"
    t.index ["order_id"], name: "index_seat_hold_sessions_on_order_id", unique: true
    t.index ["status", "expires_at"], name: "index_seat_hold_sessions_on_status_and_expires_at"
    t.index ["token_digest"], name: "index_seat_hold_sessions_on_token_digest", unique: true
    t.index ["user_id"], name: "index_seat_hold_sessions_on_user_id"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2, 3, 4])", name: "seat_hold_sessions_status_valid"
  end

  create_table "seat_holds", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "event_seat_id", null: false
    t.bigint "order_item_id"
    t.bigint "pricing_tier_id"
    t.string "release_reason"
    t.datetime "released_at"
    t.bigint "seat_hold_session_id", null: false
    t.integer "status", default: 0, null: false
    t.integer "unit_price_cents", null: false
    t.datetime "updated_at", null: false
    t.index ["event_seat_id"], name: "index_seat_holds_on_event_seat_id"
    t.index ["event_seat_id"], name: "index_seat_holds_one_blocking_per_event_seat", unique: true, where: "(status = ANY (ARRAY[0, 1]))"
    t.index ["order_item_id"], name: "index_seat_holds_on_order_item_id"
    t.index ["pricing_tier_id"], name: "index_seat_holds_on_pricing_tier_id"
    t.index ["seat_hold_session_id", "event_seat_id"], name: "index_seat_holds_on_session_and_event_seat", unique: true
    t.index ["seat_hold_session_id"], name: "index_seat_holds_on_seat_hold_session_id"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2, 3, 4])", name: "seat_holds_status_valid"
    t.check_constraint "unit_price_cents >= 0", name: "seat_holds_price_nonnegative"
  end

  create_table "seating_price_zones", force: :cascade do |t|
    t.string "code", null: false
    t.string "color", default: "#2563EB", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.integer "position", default: 0, null: false
    t.datetime "updated_at", null: false
    t.bigint "venue_layout_id", null: false
    t.index ["venue_layout_id", "code"], name: "index_seating_price_zones_on_venue_layout_id_and_code", unique: true
    t.index ["venue_layout_id"], name: "index_seating_price_zones_on_venue_layout_id"
  end

  create_table "seating_rows", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "label", null: false
    t.integer "position", default: 0, null: false
    t.bigint "seating_section_id", null: false
    t.datetime "updated_at", null: false
    t.index ["seating_section_id", "label"], name: "index_seating_rows_on_seating_section_id_and_label", unique: true
    t.index ["seating_section_id"], name: "index_seating_rows_on_seating_section_id"
  end

  create_table "seating_sections", force: :cascade do |t|
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.integer "position", default: 0, null: false
    t.datetime "updated_at", null: false
    t.bigint "venue_layout_id", null: false
    t.index ["venue_layout_id", "code"], name: "index_seating_sections_on_venue_layout_id_and_code", unique: true
    t.index ["venue_layout_id"], name: "index_seating_sections_on_venue_layout_id"
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
    t.integer "platform_processing_fee_cents", default: 0, null: false
    t.string "finalized_reader"
    t.datetime "finalized_recorded_at"
    t.string "reader_digest"
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
    t.check_constraint "platform_processing_fee_cents >= 0", name: "settlements_platform_processing_fee_nonnegative"
    t.check_constraint "processing_fee_cents >= 0", name: "settlements_processing_fee_nonnegative"
    t.check_constraint "refund_cents >= 0", name: "settlements_refund_nonnegative"
    t.check_constraint "reserve_cents >= 0", name: "settlements_reserve_nonnegative"
    t.check_constraint "status = ANY (ARRAY[0, 1])", name: "settlements_status_valid"
    t.check_constraint "version > 0", name: "settlements_version_positive"
  end

  create_table "site_settings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "payment_mode", default: "simulate", null: false
    t.string "platform_email"
    t.string "platform_name", default: "HåfaPass"
    t.string "platform_phone"
    t.integer "service_fee_flat_cents", default: 100
    t.decimal "service_fee_percent", precision: 5, scale: 2, default: "5.0"
    t.integer "singleton_guard", default: 0, null: false
    t.datetime "updated_at", null: false
    t.string "processing_fee_bearer", default: "platform", null: false
    t.string "payout_schedule_text", default: "within 3 business days after your event", null: false
    t.text "business_mailing_address"
    t.boolean "retention_purge_enabled", default: false, null: false
    t.integer "fee_notice_days", default: 30, null: false
    t.string "backup_withholding_mode", default: "block", null: false
    t.integer "backup_withholding_rate_bps", default: 2400, null: false
    t.jsonb "tax_reporting_thresholds", default: {"1099-k"=>2000000, "1099-nec"=>200000, "1099-misc"=>200000}, null: false
    t.index ["singleton_guard"], name: "index_site_settings_on_singleton_guard", unique: true
    t.check_constraint "backup_withholding_mode::text = ANY (ARRAY['block'::character varying::text, 'withhold'::character varying::text])", name: "site_settings_backup_withholding_mode_valid"
    t.check_constraint "processing_fee_bearer::text = ANY (ARRAY['platform'::character varying::text, 'organizer'::character varying::text])", name: "site_settings_processing_fee_bearer_valid"
  end

  create_table "solid_queue_batch_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "batch_id", null: false
    t.datetime "created_at", null: false
    t.index ["batch_id"], name: "index_solid_queue_batch_executions_on_batch_id"
    t.index ["job_id"], name: "index_solid_queue_batch_executions_on_job_id", unique: true
  end

  create_table "solid_queue_batches", force: :cascade do |t|
    t.string "active_job_batch_id"
    t.string "description"
    t.text "on_finish"
    t.text "on_success"
    t.text "on_failure"
    t.text "metadata"
    t.integer "total_jobs", default: 0, null: false
    t.integer "completed_jobs", default: 0, null: false
    t.integer "failed_jobs", default: 0, null: false
    t.datetime "enqueued_at"
    t.datetime "finished_at"
    t.datetime "failed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active_job_batch_id"], name: "index_solid_queue_batches_on_active_job_batch_id", unique: true
    t.index ["finished_at"], name: "index_solid_queue_batches_on_finished_at"
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.string "concurrency_key", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.text "error"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "queue_name", null: false
    t.string "class_name", null: false
    t.text "arguments"
    t.integer "priority", default: 0, null: false
    t.string "active_job_id"
    t.datetime "scheduled_at"
    t.datetime "finished_at"
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "batch_id"
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["batch_id"], name: "index_solid_queue_jobs_on_batch_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.string "queue_name", null: false
    t.datetime "created_at", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.bigint "supervisor_id"
    t.integer "pid", null: false
    t.string "hostname"
    t.text "metadata"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "task_key", null: false
    t.datetime "run_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.string "key", null: false
    t.string "schedule", null: false
    t.string "command", limit: 2048
    t.string "class_name"
    t.text "arguments"
    t.string "queue_name"
    t.integer "priority", default: 0
    t.boolean "static", default: true, null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "scheduled_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.string "key", null: false
    t.integer "value", default: 1, null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "stripe_fee_evidences", force: :cascade do |t|
    t.bigint "payment_id", null: false
    t.bigint "fee_component_id"
    t.string "status", default: "pending", null: false
    t.string "context_digest", null: false
    t.string "provider_charge_id"
    t.string "provider_balance_transaction_id"
    t.string "evidence_digest"
    t.integer "amount_cents"
    t.integer "fee_cents"
    t.integer "net_cents"
    t.string "currency"
    t.string "balance_status"
    t.jsonb "fee_details", default: [], null: false
    t.integer "attempts", default: 0, null: false
    t.string "last_error_code"
    t.datetime "next_attempt_at"
    t.datetime "verified_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "facts_recorded_at"
    t.index ["context_digest", "provider_balance_transaction_id"], name: "idx_stripe_fee_provider_identity", unique: true, where: "(provider_balance_transaction_id IS NOT NULL)"
    t.index ["fee_component_id"], name: "index_stripe_fee_evidences_on_fee_component_id", unique: true
    t.index ["payment_id"], name: "index_stripe_fee_evidences_on_payment_id", unique: true
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'verified'::character varying::text, 'review_required'::character varying::text])", name: "stripe_fee_evidence_status"
  end

  create_table "support_notes", force: :cascade do |t|
    t.bigint "author_user_id", null: false
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.bigint "event_id"
    t.bigint "order_id"
    t.bigint "ticket_id"
    t.datetime "updated_at", null: false
    t.datetime "retention_anonymized_at"
    t.index ["author_user_id"], name: "index_support_notes_on_author_user_id"
    t.index ["event_id", "created_at"], name: "index_support_notes_on_event_id_and_created_at"
    t.index ["event_id"], name: "index_support_notes_on_event_id"
    t.index ["order_id", "created_at"], name: "index_support_notes_on_order_id_and_created_at"
    t.index ["order_id"], name: "index_support_notes_on_order_id"
    t.index ["retention_anonymized_at"], name: "index_support_notes_on_retention_anonymized_at"
    t.index ["ticket_id", "created_at"], name: "index_support_notes_on_ticket_id_and_created_at"
    t.index ["ticket_id"], name: "index_support_notes_on_ticket_id"
    t.check_constraint "order_id IS NOT NULL OR ticket_id IS NOT NULL OR event_id IS NOT NULL", name: "support_notes_subject_present"
  end

  create_table "ticket_inventory_retentions", force: :cascade do |t|
    t.bigint "ticket_id", null: false
    t.bigint "refund_id"
    t.bigint "dispute_id"
    t.bigint "reconciliation_exception_id", null: false
    t.datetime "retained_at", null: false
    t.index ["dispute_id"], name: "index_ticket_inventory_retentions_on_dispute_id"
    t.index ["reconciliation_exception_id"], name: "index_ticket_retentions_on_reconciliation"
    t.index ["refund_id"], name: "index_ticket_inventory_retentions_on_refund_id"
    t.index ["ticket_id"], name: "index_ticket_inventory_retentions_on_ticket_id", unique: true
    t.check_constraint "refund_id IS NOT NULL AND dispute_id IS NULL OR refund_id IS NULL AND dispute_id IS NOT NULL", name: "ticket_inventory_retentions_one_origin"
  end

  create_table "ticket_transfers", force: :cascade do |t|
    t.datetime "accepted_at"
    t.bigint "accepted_by_user_id"
    t.datetime "cancelled_at"
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "initiated_by_user_id"
    t.string "recipient_email", null: false
    t.string "recipient_name"
    t.integer "status", default: 0, null: false
    t.bigint "ticket_id", null: false
    t.integer "token_version", default: 0, null: false
    t.datetime "updated_at", null: false
    t.string "locale", default: "en", null: false
    t.datetime "retention_anonymized_at"
    t.index "lower((recipient_email)::text)", name: "index_ticket_transfers_on_lower_recipient"
    t.index ["accepted_by_user_id"], name: "index_ticket_transfers_on_accepted_by_user_id"
    t.index ["initiated_by_user_id"], name: "index_ticket_transfers_on_initiated_by_user_id"
    t.index ["retention_anonymized_at"], name: "index_ticket_transfers_on_retention_anonymized_at"
    t.index ["ticket_id"], name: "index_ticket_transfers_on_ticket_id"
    t.index ["ticket_id"], name: "index_ticket_transfers_one_pending", unique: true, where: "(status = 0)"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2, 3, 4])", name: "ticket_transfers_status_valid"
  end

  create_table "ticket_type_included_events", force: :cascade do |t|
    t.bigint "ticket_type_id", null: false
    t.bigint "included_event_id", null: false
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["included_event_id"], name: "index_ticket_type_included_events_on_included_event_id"
    t.index ["ticket_type_id", "included_event_id"], name: "index_ticket_type_included_events_uniqueness", unique: true
    t.check_constraint "\"position\" >= 0", name: "chk_ticket_type_included_events_position_nonnegative"
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
    t.jsonb "translations", default: {}, null: false
    t.string "translation_status", default: "untranslated", null: false
    t.datetime "translation_requested_at"
    t.boolean "is_pass", default: false, null: false
    t.string "attendee_info_mode", default: "none", null: false
    t.string "door_check_mode", default: "instant", null: false
    t.string "door_alert_label", limit: 120
    t.text "door_instructions"
    t.boolean "scanner_show_buyer", default: false, null: false
    t.index ["event_id"], name: "index_ticket_types_on_event_id"
    t.check_constraint "attendee_info_mode::text = ANY (ARRAY['none'::character varying::text, 'name_only'::character varying::text, 'name_and_email'::character varying::text])", name: "ticket_types_attendee_info_mode_valid"
    t.check_constraint "door_allocation IS NULL OR door_allocation >= 0", name: "ticket_types_door_allocation_nonnegative"
    t.check_constraint "door_check_mode::text = ANY (ARRAY['instant'::character varying::text, 'verify'::character varying::text])", name: "ticket_types_door_check_mode_valid"
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
    t.bigint "event_seat_id"
    t.string "holder_email"
    t.bigint "holder_user_id"
    t.bigint "order_id", null: false
    t.bigint "order_item_id"
    t.bigint "pricing_tier_id"
    t.string "qr_code"
    t.integer "scan_credential_version", default: 1, null: false
    t.integer "status", default: 0, null: false
    t.bigint "ticket_type_id", null: false
    t.datetime "updated_at", null: false
    t.datetime "first_admitted_at"
    t.datetime "retention_anonymized_at"
    t.bigint "parent_ticket_id"
    t.string "occupancy_state", default: "outside", null: false
    t.date "occupancy_day"
    t.datetime "last_entry_at"
    t.datetime "last_exit_at"
    t.bigint "last_entry_device_id"
    t.integer "re_entry_count", default: 0, null: false
    t.boolean "re_entry_conflict_flagged", default: false, null: false
    t.index "lower((holder_email)::text)", name: "index_tickets_on_lower_holder_email"
    t.index ["event_id", "occupancy_state"], name: "index_tickets_on_event_id_and_occupancy_state"
    t.index ["event_id"], name: "index_tickets_on_event_id"
    t.index ["event_seat_id"], name: "index_tickets_on_event_seat_id"
    t.index ["event_seat_id"], name: "index_tickets_one_active_per_event_seat", unique: true, where: "((event_seat_id IS NOT NULL) AND (status = ANY (ARRAY[0, 1, 3])))"
    t.index ["holder_user_id"], name: "index_tickets_on_holder_user_id"
    t.index ["last_entry_device_id"], name: "index_tickets_on_last_entry_device_id", where: "(last_entry_device_id IS NOT NULL)"
    t.index ["order_id"], name: "index_tickets_on_order_id"
    t.index ["order_item_id"], name: "index_tickets_on_order_item_id"
    t.index ["parent_ticket_id", "event_id"], name: "index_tickets_on_parent_ticket_id_and_event_id", unique: true, where: "(parent_ticket_id IS NOT NULL)"
    t.index ["parent_ticket_id"], name: "index_tickets_on_parent_ticket_id"
    t.index ["pricing_tier_id"], name: "index_tickets_on_pricing_tier_id"
    t.index ["qr_code"], name: "index_tickets_on_qr_code", unique: true
    t.index ["retention_anonymized_at"], name: "index_tickets_on_retention_anonymized_at"
    t.index ["ticket_type_id"], name: "index_tickets_on_ticket_type_id"
    t.check_constraint "display_credential_version > 0", name: "tickets_display_version_positive"
    t.check_constraint "occupancy_state::text = ANY (ARRAY['outside'::character varying::text, 'inside'::character varying::text])", name: "tickets_occupancy_state_valid"
    t.check_constraint "parent_ticket_id IS NULL OR order_item_id IS NULL", name: "chk_tickets_pass_child_no_order_item"
    t.check_constraint "re_entry_count >= 0", name: "tickets_re_entry_count_non_negative"
    t.check_constraint "scan_credential_version > 0", name: "tickets_scan_version_positive"
  end

  create_table "tin_match_requests", force: :cascade do |t|
    t.bigint "organizer_tax_information_id", null: false
    t.string "account_reference", null: false
    t.datetime "tax_information_updated_at", null: false
    t.datetime "exported_at", null: false
    t.datetime "imported_at"
    t.integer "result_code"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_reference"], name: "index_tin_match_requests_on_account_reference", unique: true
    t.index ["organizer_tax_information_id"], name: "index_tin_match_requests_on_organizer_tax_information_id"
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
    t.datetime "clerk_profile_checked_at"
    t.index ["clerk_id"], name: "index_users_on_clerk_id", unique: true
  end

  create_table "venue_layouts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "organization_id", null: false
    t.string "provider_chart_key"
    t.integer "renderer", default: 0, null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.bigint "venue_id", null: false
    t.integer "version", default: 1, null: false
    t.index ["organization_id", "venue_id", "name", "version"], name: "index_venue_layouts_on_owner_venue_name_version", unique: true
    t.index ["organization_id"], name: "index_venue_layouts_on_organization_id"
    t.index ["venue_id"], name: "index_venue_layouts_on_venue_id"
    t.check_constraint "renderer = ANY (ARRAY[0, 1])", name: "venue_layouts_renderer_valid"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2])", name: "venue_layouts_status_valid"
    t.check_constraint "version > 0", name: "venue_layouts_version_positive"
  end

  create_table "venue_seats", force: :cascade do |t|
    t.integer "accessibility_kind", default: 0, null: false
    t.boolean "active", default: true, null: false
    t.string "companion_group"
    t.datetime "created_at", null: false
    t.string "label", null: false
    t.boolean "obstructed_view", default: false, null: false
    t.integer "position", null: false
    t.bigint "seating_price_zone_id", null: false
    t.bigint "seating_row_id", null: false
    t.datetime "updated_at", null: false
    t.string "view_note"
    t.decimal "x", precision: 10, scale: 3
    t.decimal "y", precision: 10, scale: 3
    t.index ["seating_price_zone_id"], name: "index_venue_seats_on_seating_price_zone_id"
    t.index ["seating_row_id", "label"], name: "index_venue_seats_on_seating_row_id_and_label", unique: true
    t.index ["seating_row_id", "position"], name: "index_venue_seats_on_seating_row_id_and_position", unique: true
    t.index ["seating_row_id"], name: "index_venue_seats_on_seating_row_id"
    t.check_constraint "\"position\" >= 0", name: "venue_seats_position_nonnegative"
    t.check_constraint "accessibility_kind = ANY (ARRAY[0, 1, 2, 3])", name: "venue_seats_accessibility_kind_valid"
  end

  create_table "venue_slug_redirects", force: :cascade do |t|
    t.bigint "venue_id", null: false
    t.string "slug", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_venue_slug_redirects_on_slug", unique: true
    t.index ["venue_id"], name: "index_venue_slug_redirects_on_venue_id"
  end

  create_table "venues", force: :cascade do |t|
    t.text "accessibility_notes"
    t.boolean "active", default: true, null: false
    t.string "address", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.boolean "verified", default: false, null: false
    t.string "village", null: false
    t.string "website_url"
    t.index "lower(translate((village)::text, 'åàáâäãāéèêëēíìîïīóòôöõōúùûüūñÅÀÁÂÄÃĀÉÈÊËĒÍÌÎÏĪÓÒÔÖÕŌÚÙÛÜŪÑ'::text, 'aaaaaaaeeeeeiiiiioooooouuuuunaaaaaaaeeeeeiiiiioooooouuuuun'::text))", name: "index_venues_on_folded_village"
    t.index ["active", "village", "name"], name: "index_venues_on_active_and_village_and_name"
    t.index ["slug"], name: "index_venues_on_slug", unique: true
  end

  create_table "waitlist_entries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.bigint "event_id", null: false
    t.datetime "expires_at"
    t.integer "management_version", default: 0, null: false
    t.string "name"
    t.datetime "notified_at"
    t.string "phone"
    t.integer "position", null: false
    t.integer "quantity", default: 1, null: false
    t.integer "status", default: 0, null: false
    t.bigint "ticket_type_id"
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.string "locale", default: "en", null: false
    t.datetime "requested_at"
    t.string "request_ip"
    t.text "request_user_agent"
    t.string "delivery_failure"
    t.index ["event_id", "ticket_type_id", "email"], name: "idx_waitlist_unique_entry", unique: true
    t.index ["event_id", "ticket_type_id", "position"], name: "idx_on_event_id_ticket_type_id_position_e28bca8bda"
    t.index ["event_id"], name: "index_waitlist_entries_on_event_id"
    t.index ["ticket_type_id"], name: "index_waitlist_entries_on_ticket_type_id"
    t.index ["user_id"], name: "index_waitlist_entries_on_user_id"
  end

  create_table "waitlist_offers", force: :cascade do |t|
    t.datetime "claimed_at"
    t.datetime "converted_at"
    t.datetime "created_at", null: false
    t.bigint "event_id", null: false
    t.datetime "expires_at", null: false
    t.bigint "order_id"
    t.bigint "pricing_tier_id"
    t.integer "quantity", null: false
    t.integer "status", default: 0, null: false
    t.bigint "ticket_type_id", null: false
    t.integer "token_version", default: 0, null: false
    t.integer "unit_price_cents", null: false
    t.datetime "updated_at", null: false
    t.bigint "waitlist_entry_id", null: false
    t.string "cancel_reason"
    t.index ["event_id"], name: "index_waitlist_offers_on_event_id"
    t.index ["order_id"], name: "index_waitlist_offers_on_order_id"
    t.index ["pricing_tier_id"], name: "index_waitlist_offers_on_pricing_tier_id"
    t.index ["ticket_type_id", "status", "expires_at"], name: "index_waitlist_offer_inventory"
    t.index ["ticket_type_id"], name: "index_waitlist_offers_on_ticket_type_id"
    t.index ["waitlist_entry_id"], name: "index_waitlist_offers_on_waitlist_entry_id"
    t.index ["waitlist_entry_id"], name: "index_waitlist_offers_one_active", unique: true, where: "(status = ANY (ARRAY[0, 1]))"
    t.check_constraint "quantity > 0", name: "waitlist_offers_quantity_positive"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2, 3, 4])", name: "waitlist_offers_status_valid"
    t.check_constraint "unit_price_cents >= 0", name: "waitlist_offers_price_nonnegative"
  end

  create_table "waiver_acceptances", force: :cascade do |t|
    t.datetime "accepted_at", null: false
    t.string "content_digest", null: false
    t.datetime "created_at", null: false
    t.bigint "event_waiver_id", null: false
    t.bigint "order_id", null: false
    t.datetime "updated_at", null: false
    t.string "version", null: false
    t.index ["event_waiver_id"], name: "index_waiver_acceptances_on_event_waiver_id"
    t.index ["order_id", "event_waiver_id"], name: "index_waiver_acceptances_on_order_id_and_event_waiver_id", unique: true
    t.index ["order_id"], name: "index_waiver_acceptances_on_order_id"
  end

  create_table "wallet_passes", force: :cascade do |t|
    t.bigint "ticket_id", null: false
    t.string "provider", null: false
    t.string "serial_number", null: false
    t.integer "scan_credential_version", null: false
    t.string "authentication_token_digests", default: [], null: false, array: true
    t.string "content_digest"
    t.datetime "content_updated_at"
    t.string "synced_digest"
    t.datetime "synced_at"
    t.integer "sync_attempts", default: 0, null: false
    t.text "last_error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["provider", "serial_number"], name: "index_wallet_passes_on_provider_and_serial_number", unique: true
    t.index ["ticket_id"], name: "index_wallet_passes_on_ticket_id"
    t.check_constraint "provider::text = ANY (ARRAY['apple'::character varying::text, 'google'::character varying::text])", name: "wallet_passes_provider_known"
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
    t.datetime "retention_anonymized_at"
    t.datetime "replayed_at"
    t.string "provider_payment_intent_id"
    t.string "provider_object_id"
    t.boolean "provider_livemode"
    t.string "provider_account_id"
    t.bigint "provider_amount_cents"
    t.string "provider_currency"
    t.index ["provider", "provider_event_id"], name: "index_webhook_events_on_unique_provider_event", unique: true
    t.index ["provider_payment_intent_id"], name: "index_webhook_events_on_provider_payment_intent_id", where: "(provider_payment_intent_id IS NOT NULL)"
    t.index ["retention_anonymized_at"], name: "index_webhook_events_on_retention_anonymized_at"
    t.index ["status", "created_at"], name: "index_webhook_events_on_status_and_created_at"
    t.check_constraint "attempts >= 0", name: "webhook_events_attempts_nonnegative"
    t.check_constraint "status = ANY (ARRAY[0, 1, 2, 3, 4])", name: "webhook_events_status_valid"
  end

  create_table "webhook_rejection_counts", force: :cascade do |t|
    t.string "provider", null: false
    t.string "reason", null: false
    t.datetime "bucket_started_at", null: false
    t.integer "count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["bucket_started_at"], name: "index_webhook_rejection_counts_on_bucket_started_at"
    t.index ["provider", "reason", "bucket_started_at"], name: "index_webhook_rejection_counts_on_bucket", unique: true
    t.check_constraint "count >= 0", name: "webhook_rejection_counts_nonnegative"
  end

  add_foreign_key "accessible_seat_releases", "event_seats", on_delete: :restrict
  add_foreign_key "accessible_seat_releases", "users", column: "released_by_user_id", on_delete: :restrict
  add_foreign_key "acquisition_attributions", "distribution_links", on_delete: :restrict
  add_foreign_key "acquisition_attributions", "event_referrals", on_delete: :restrict
  add_foreign_key "acquisition_attributions", "orders", on_delete: :restrict
  add_foreign_key "admission_actions", "admission_actions", column: "reverses_action_id", on_delete: :restrict
  add_foreign_key "admission_actions", "events", on_delete: :restrict
  add_foreign_key "admission_actions", "organizations", on_delete: :restrict
  add_foreign_key "admission_actions", "scanner_devices", on_delete: :restrict
  add_foreign_key "admission_actions", "tickets", on_delete: :restrict
  add_foreign_key "admission_actions", "users", column: "actor_user_id", on_delete: :restrict
  add_foreign_key "admission_manifests", "events", on_delete: :restrict
  add_foreign_key "admission_manifests", "organizations", on_delete: :restrict
  add_foreign_key "admission_manifests", "users", column: "generated_by_user_id", on_delete: :restrict
  add_foreign_key "annual_tax_report_settings", "organizations"
  add_foreign_key "apple_wallet_registrations", "wallet_passes"
  add_foreign_key "audience_mailings", "organizations"
  add_foreign_key "audience_mailings", "users", column: "created_by_id"
  add_foreign_key "audit_logs", "organizations", on_delete: :restrict
  add_foreign_key "balance_adjustments", "balance_adjustments", column: "reversal_of_id", on_delete: :restrict
  add_foreign_key "balance_adjustments", "disputes", on_delete: :restrict
  add_foreign_key "balance_adjustments", "events", on_delete: :restrict
  add_foreign_key "balance_adjustments", "orders", on_delete: :restrict
  add_foreign_key "balance_adjustments", "organizations", on_delete: :restrict
  add_foreign_key "balance_adjustments", "users", column: "created_by_user_id", on_delete: :nullify
  add_foreign_key "balance_adjustments", "users", column: "reversed_by_user_id", on_delete: :nullify
  add_foreign_key "buyer_return_postings", "buyer_return_postings", column: "reverses_posting_id"
  add_foreign_key "buyer_return_postings", "never_fulfilled_captures"
  add_foreign_key "card_present_accounts", "organizations", on_delete: :restrict
  add_foreign_key "card_present_accounts", "users", column: "verified_by_user_id", on_delete: :restrict
  add_foreign_key "card_present_payment_attempts", "card_present_accounts", on_delete: :restrict
  add_foreign_key "card_present_payment_attempts", "events", on_delete: :restrict
  add_foreign_key "card_present_payment_attempts", "orders", on_delete: :restrict
  add_foreign_key "card_present_payment_attempts", "organizations", on_delete: :restrict
  add_foreign_key "card_present_payment_attempts", "payments", on_delete: :restrict
  add_foreign_key "card_present_payment_attempts", "users", column: "initiated_by_user_id", on_delete: :restrict
  add_foreign_key "catalog_fulfillments", "order_items", on_delete: :restrict
  add_foreign_key "catalog_fulfillments", "users", column: "fulfilled_by_user_id", on_delete: :restrict
  add_foreign_key "catalog_item_holds", "catalog_items", on_delete: :restrict
  add_foreign_key "catalog_item_holds", "order_items", on_delete: :restrict
  add_foreign_key "catalog_item_holds", "orders", on_delete: :restrict
  add_foreign_key "catalog_items", "events", on_delete: :restrict
  add_foreign_key "checkout_attempts", "orders"
  add_foreign_key "communication_campaigns", "events", on_delete: :restrict
  add_foreign_key "communication_campaigns", "users", column: "created_by_user_id", on_delete: :restrict
  add_foreign_key "communication_campaigns", "users", column: "scheduled_by_user_id"
  add_foreign_key "communication_campaigns", "users", column: "sent_by_user_id"
  add_foreign_key "connected_accounts", "organizations", on_delete: :restrict
  add_foreign_key "disputes", "orders", on_delete: :restrict
  add_foreign_key "disputes", "payments", on_delete: :restrict
  add_foreign_key "distribution_links", "distribution_partners", on_delete: :restrict
  add_foreign_key "distribution_links", "events", on_delete: :restrict
  add_foreign_key "distribution_links", "users", column: "created_by_user_id", on_delete: :restrict
  add_foreign_key "email_consents", "organizations"
  add_foreign_key "event_cancellation_refund_items", "event_cancellation_refund_runs"
  add_foreign_key "event_cancellation_refund_items", "orders"
  add_foreign_key "event_cancellation_refund_runs", "events"
  add_foreign_key "event_cancellation_refund_runs", "users", column: "started_by_id"
  add_foreign_key "event_change_responses", "event_changes", on_delete: :restrict
  add_foreign_key "event_change_responses", "orders", on_delete: :restrict
  add_foreign_key "event_changes", "events", on_delete: :restrict
  add_foreign_key "event_changes", "users", column: "actor_user_id", on_delete: :nullify
  add_foreign_key "event_day_rehearsal_reviews", "event_day_rehearsal_reviews", column: "parent_review_id", on_delete: :restrict
  add_foreign_key "event_day_rehearsal_reviews", "events", on_delete: :restrict
  add_foreign_key "event_day_rehearsal_reviews", "pilot_validation_reviews", on_delete: :restrict
  add_foreign_key "event_day_rehearsal_reviews", "users", column: "actor_user_id", on_delete: :restrict
  add_foreign_key "event_favorites", "events", on_delete: :cascade
  add_foreign_key "event_favorites", "users", on_delete: :cascade
  add_foreign_key "event_price_zones", "event_seating_configurations", on_delete: :cascade
  add_foreign_key "event_price_zones", "seating_price_zones", on_delete: :restrict
  add_foreign_key "event_price_zones", "ticket_types", on_delete: :restrict
  add_foreign_key "event_referrals", "events", on_delete: :restrict
  add_foreign_key "event_referrals", "users", on_delete: :cascade
  add_foreign_key "event_reminders", "events", on_delete: :cascade
  add_foreign_key "event_reminders", "users", on_delete: :cascade
  add_foreign_key "event_seating_configurations", "events", on_delete: :restrict
  add_foreign_key "event_seating_configurations", "venue_layouts", on_delete: :restrict
  add_foreign_key "event_seats", "event_seating_configurations", on_delete: :restrict
  add_foreign_key "event_seats", "ticket_types", on_delete: :restrict
  add_foreign_key "event_seats", "venue_seats", on_delete: :restrict
  add_foreign_key "event_series", "organizations"
  add_foreign_key "event_series_memberships", "event_series", on_delete: :cascade
  add_foreign_key "event_series_memberships", "events", on_delete: :cascade
  add_foreign_key "event_slug_redirects", "events"
  add_foreign_key "event_staff_assignments", "events", on_delete: :restrict
  add_foreign_key "event_staff_assignments", "organizations", on_delete: :restrict
  add_foreign_key "event_staff_assignments", "users", column: "assigned_by_user_id", on_delete: :nullify
  add_foreign_key "event_staff_assignments", "users", on_delete: :restrict
  add_foreign_key "event_state_changes", "events"
  add_foreign_key "event_state_changes", "users", column: "actor_user_id"
  add_foreign_key "event_waivers", "events", on_delete: :restrict
  add_foreign_key "events", "organizations", on_delete: :restrict
  add_foreign_key "events", "organizer_profiles"
  add_foreign_key "events", "users", column: "policy_hold_by_user_id"
  add_foreign_key "events", "venues", on_delete: :restrict
  add_foreign_key "fee_change_notices", "events"
  add_foreign_key "fee_change_notices", "fee_changes"
  add_foreign_key "fee_change_notices", "organizations"
  add_foreign_key "fee_change_notices", "users", column: "owner_id"
  add_foreign_key "fee_changes", "platform_capability_reviews", column: "preapproval_id"
  add_foreign_key "fee_changes", "users", column: "created_by_id"
  add_foreign_key "fee_components", "order_items", on_delete: :restrict
  add_foreign_key "fee_components", "orders", on_delete: :restrict
  add_foreign_key "guest_list_entries", "events"
  add_foreign_key "guest_list_entries", "orders"
  add_foreign_key "guest_list_entries", "ticket_types"
  add_foreign_key "image_upload_receipts", "events", on_delete: :cascade
  add_foreign_key "image_upload_receipts", "organizations", on_delete: :cascade
  add_foreign_key "image_upload_receipts", "users", on_delete: :cascade
  add_foreign_key "inventory_holds", "events", on_delete: :restrict
  add_foreign_key "inventory_holds", "order_items", on_delete: :restrict
  add_foreign_key "inventory_holds", "orders", on_delete: :restrict
  add_foreign_key "inventory_holds", "pricing_tiers", on_delete: :restrict
  add_foreign_key "inventory_holds", "ticket_types", on_delete: :restrict
  add_foreign_key "legal_holds", "users", column: "placed_by_id", on_delete: :restrict
  add_foreign_key "legal_holds", "users", column: "released_by_id", on_delete: :restrict
  add_foreign_key "live_money_proof_authorizations", "connected_accounts", on_delete: :restrict
  add_foreign_key "live_money_proof_authorizations", "event_day_rehearsal_reviews", on_delete: :restrict
  add_foreign_key "live_money_proof_authorizations", "events", on_delete: :restrict
  add_foreign_key "live_money_proof_authorizations", "orders", on_delete: :restrict
  add_foreign_key "live_money_proof_authorizations", "users", column: "approved_by_user_id", on_delete: :restrict
  add_foreign_key "live_money_proof_authorizations", "users", column: "requested_by_user_id", on_delete: :restrict
  add_foreign_key "live_money_proof_reviews", "connected_accounts", on_delete: :restrict
  add_foreign_key "live_money_proof_reviews", "event_day_rehearsal_reviews", on_delete: :restrict
  add_foreign_key "live_money_proof_reviews", "events", column: "proof_event_id", on_delete: :restrict
  add_foreign_key "live_money_proof_reviews", "live_money_proof_authorizations", column: "authorization_id", on_delete: :restrict
  add_foreign_key "live_money_proof_reviews", "live_money_proof_reviews", column: "parent_review_id", on_delete: :restrict
  add_foreign_key "live_money_proof_reviews", "orders", on_delete: :restrict
  add_foreign_key "live_money_proof_reviews", "organizations", on_delete: :restrict
  add_foreign_key "live_money_proof_reviews", "payments", on_delete: :restrict
  add_foreign_key "live_money_proof_reviews", "payouts", on_delete: :restrict
  add_foreign_key "live_money_proof_reviews", "refunds", column: "final_refund_id", on_delete: :restrict
  add_foreign_key "live_money_proof_reviews", "refunds", column: "partial_refund_id", on_delete: :restrict
  add_foreign_key "live_money_proof_reviews", "settlements", column: "initial_settlement_id", on_delete: :restrict
  add_foreign_key "live_money_proof_reviews", "settlements", column: "post_payout_settlement_id", on_delete: :restrict
  add_foreign_key "live_money_proof_reviews", "users", column: "actor_user_id", on_delete: :restrict
  add_foreign_key "live_pilot_incidents", "events", on_delete: :restrict
  add_foreign_key "live_pilot_incidents", "live_pilot_incidents", column: "parent_incident_id", on_delete: :restrict
  add_foreign_key "live_pilot_incidents", "live_pilot_runs", on_delete: :restrict
  add_foreign_key "live_pilot_incidents", "users", column: "actor_user_id", on_delete: :restrict
  add_foreign_key "live_pilot_metric_snapshots", "events", on_delete: :restrict
  add_foreign_key "live_pilot_metric_snapshots", "live_pilot_runs", on_delete: :restrict
  add_foreign_key "live_pilot_metric_snapshots", "users", column: "recorded_by_user_id", on_delete: :restrict
  add_foreign_key "live_pilot_reviews", "event_day_rehearsal_reviews", on_delete: :restrict
  add_foreign_key "live_pilot_reviews", "events", on_delete: :restrict
  add_foreign_key "live_pilot_reviews", "live_money_proof_reviews", on_delete: :restrict
  add_foreign_key "live_pilot_reviews", "live_pilot_reviews", column: "parent_review_id", on_delete: :restrict
  add_foreign_key "live_pilot_reviews", "users", column: "actor_user_id", on_delete: :restrict
  add_foreign_key "live_pilot_run_actions", "events", on_delete: :restrict
  add_foreign_key "live_pilot_run_actions", "live_pilot_runs", on_delete: :restrict
  add_foreign_key "live_pilot_run_actions", "users", column: "actor_user_id", on_delete: :restrict
  add_foreign_key "live_pilot_runs", "events", on_delete: :restrict
  add_foreign_key "live_pilot_runs", "live_pilot_reviews", on_delete: :restrict
  add_foreign_key "live_pilot_runs", "users", column: "completed_by_user_id", on_delete: :restrict
  add_foreign_key "live_pilot_runs", "users", column: "started_by_user_id", on_delete: :restrict
  add_foreign_key "marketing_unsubscribes", "organizations"
  add_foreign_key "marketplace_collection_events", "events", on_delete: :restrict
  add_foreign_key "marketplace_collection_events", "marketplace_collections", on_delete: :cascade
  add_foreign_key "marketplace_collections", "users", column: "created_by_user_id", on_delete: :restrict
  add_foreign_key "marketplace_funnel_events", "distribution_links", on_delete: :restrict
  add_foreign_key "marketplace_funnel_events", "event_referrals", on_delete: :restrict
  add_foreign_key "marketplace_funnel_events", "events", on_delete: :restrict
  add_foreign_key "marketplace_funnel_events", "orders", on_delete: :restrict
  add_foreign_key "message_deliveries", "audience_mailings"
  add_foreign_key "message_deliveries", "communication_campaigns", on_delete: :restrict
  add_foreign_key "message_deliveries", "events", on_delete: :restrict
  add_foreign_key "message_deliveries", "orders", on_delete: :restrict
  add_foreign_key "message_deliveries", "organization_memberships"
  add_foreign_key "message_deliveries", "platform_invitations"
  add_foreign_key "message_deliveries", "platform_subscribers"
  add_foreign_key "message_deliveries", "privacy_requests", on_delete: :restrict
  add_foreign_key "message_deliveries", "tickets", on_delete: :restrict
  add_foreign_key "message_deliveries", "users", column: "requested_by_id", on_delete: :nullify
  add_foreign_key "message_provider_events", "message_deliveries", on_delete: :nullify
  add_foreign_key "never_fulfilled_captures", "orders"
  add_foreign_key "never_fulfilled_captures", "payments", column: ["payment_id", "order_id"], primary_key: ["id", "order_id"], name: "fk_never_fulfilled_captures_same_order_payment"
  add_foreign_key "order_items", "catalog_items", on_delete: :restrict
  add_foreign_key "order_items", "orders", on_delete: :restrict
  add_foreign_key "order_items", "pricing_tiers", on_delete: :restrict
  add_foreign_key "order_items", "ticket_types", on_delete: :restrict
  add_foreign_key "orders", "events"
  add_foreign_key "orders", "payments", column: ["fulfilled_by_payment_id", "id"], primary_key: ["id", "order_id"], name: "fk_orders_fulfilled_by_same_order_payment"
  add_foreign_key "orders", "promo_codes"
  add_foreign_key "orders", "users"
  add_foreign_key "orders", "users", column: "sold_by_id"
  add_foreign_key "organization_invitation_dispatches", "organizations"
  add_foreign_key "organization_invitation_dispatches", "users", column: "actor_user_id"
  add_foreign_key "organization_memberships", "organizations", on_delete: :restrict
  add_foreign_key "organization_memberships", "users", column: "invited_by_user_id", on_delete: :nullify
  add_foreign_key "organization_memberships", "users", on_delete: :restrict
  add_foreign_key "organizations", "connected_accounts", column: "payout_connected_account_id"
  add_foreign_key "organizer_follows", "organizations", on_delete: :cascade
  add_foreign_key "organizer_follows", "users", on_delete: :cascade
  add_foreign_key "organizer_profiles", "organizations", on_delete: :restrict
  add_foreign_key "organizer_profiles", "users"
  add_foreign_key "organizer_profiles", "users", column: "verified_by_user_id"
  add_foreign_key "organizer_sales_export_requests", "events"
  add_foreign_key "organizer_sales_export_requests", "users", column: "actor_user_id"
  add_foreign_key "organizer_tax_informations", "organizations"
  add_foreign_key "organizer_tax_informations", "users", column: "irs_validation_admin_id"
  add_foreign_key "payment_events", "payments", on_delete: :restrict
  add_foreign_key "payment_events", "webhook_events", on_delete: :restrict
  add_foreign_key "payment_readiness_reviews", "connected_accounts", on_delete: :restrict
  add_foreign_key "payment_readiness_reviews", "payment_readiness_reviews", column: "parent_review_id", on_delete: :restrict
  add_foreign_key "payment_readiness_reviews", "users", column: "actor_user_id", on_delete: :restrict
  add_foreign_key "payments", "orders", on_delete: :restrict
  add_foreign_key "payout_check_adjustments", "payouts"
  add_foreign_key "payout_check_adjustments", "users", column: "created_by_user_id"
  add_foreign_key "payout_custody_determinations", "payouts"
  add_foreign_key "payout_line_allocations", "order_items"
  add_foreign_key "payout_line_allocations", "payouts"
  add_foreign_key "payout_return_proofs", "payouts"
  add_foreign_key "payouts", "connected_accounts", on_delete: :restrict
  add_foreign_key "payouts", "events", on_delete: :restrict
  add_foreign_key "payouts", "organizations", on_delete: :restrict
  add_foreign_key "payouts", "settlements", on_delete: :restrict
  add_foreign_key "pilot_closeout_reviews", "events", on_delete: :restrict
  add_foreign_key "pilot_closeout_reviews", "live_pilot_runs", on_delete: :restrict
  add_foreign_key "pilot_closeout_reviews", "pilot_closeout_reviews", column: "parent_review_id", on_delete: :restrict
  add_foreign_key "pilot_closeout_reviews", "users", column: "actor_user_id", on_delete: :restrict
  add_foreign_key "pilot_readiness_reviews", "events", on_delete: :restrict
  add_foreign_key "pilot_readiness_reviews", "pilot_readiness_reviews", column: "parent_review_id", on_delete: :restrict
  add_foreign_key "pilot_readiness_reviews", "users", column: "actor_user_id", on_delete: :restrict
  add_foreign_key "pilot_validation_reviews", "events", on_delete: :restrict
  add_foreign_key "pilot_validation_reviews", "pilot_readiness_reviews", on_delete: :restrict
  add_foreign_key "pilot_validation_reviews", "pilot_validation_reviews", column: "parent_review_id", on_delete: :restrict
  add_foreign_key "pilot_validation_reviews", "users", column: "actor_user_id", on_delete: :restrict
  add_foreign_key "platform_capability_reviews", "platform_capability_reviews", column: "parent_review_id", on_delete: :restrict
  add_foreign_key "platform_capability_reviews", "users", column: "actor_user_id", on_delete: :restrict
  add_foreign_key "platform_invitations", "users", column: "accepted_by_user_id"
  add_foreign_key "platform_invitations", "users", column: "invited_by_user_id"
  add_foreign_key "pricing_tiers", "ticket_types"
  add_foreign_key "privacy_requests", "orders", on_delete: :restrict
  add_foreign_key "privacy_requests", "users", column: "executed_by_id", on_delete: :restrict
  add_foreign_key "privacy_requests", "users", column: "verified_by_id", on_delete: :restrict
  add_foreign_key "privacy_requests", "users", on_delete: :nullify
  add_foreign_key "promo_codes", "events"
  add_foreign_key "promo_redemptions", "orders", on_delete: :restrict
  add_foreign_key "promo_redemptions", "promo_codes", on_delete: :restrict
  add_foreign_key "promoter_commission_entries", "orders", on_delete: :restrict
  add_foreign_key "promoter_commission_entries", "promoters", on_delete: :restrict
  add_foreign_key "promoter_commission_entries", "refunds", on_delete: :restrict
  add_foreign_key "promoters", "events", on_delete: :restrict
  add_foreign_key "reconciliation_exceptions", "orders", on_delete: :restrict
  add_foreign_key "reconciliation_exceptions", "payments", on_delete: :restrict
  add_foreign_key "reconciliation_exceptions", "webhook_events", on_delete: :restrict
  add_foreign_key "referral_attributions", "orders", on_delete: :restrict
  add_foreign_key "referral_attributions", "promoters", on_delete: :restrict
  add_foreign_key "refund_items", "order_items", on_delete: :restrict
  add_foreign_key "refund_items", "refunds", on_delete: :restrict
  add_foreign_key "refund_tickets", "refunds", on_delete: :restrict
  add_foreign_key "refund_tickets", "tickets", on_delete: :restrict
  add_foreign_key "refunds", "orders", on_delete: :restrict
  add_foreign_key "refunds", "payments", on_delete: :restrict
  add_foreign_key "refunds", "repayment_operations"
  add_foreign_key "refunds", "users", column: "requested_by_id", on_delete: :nullify
  add_foreign_key "registration_questions", "events", on_delete: :restrict
  add_foreign_key "registration_responses", "orders", on_delete: :restrict
  add_foreign_key "registration_responses", "registration_questions", on_delete: :restrict
  add_foreign_key "registration_responses", "tickets", on_delete: :restrict
  add_foreign_key "repayment_operations", "never_fulfilled_captures"
  add_foreign_key "repayment_operations", "payments"
  add_foreign_key "repayment_operations", "refunds"
  add_foreign_key "scanner_devices", "events", on_delete: :restrict
  add_foreign_key "scanner_devices", "organizations", on_delete: :restrict
  add_foreign_key "scanner_devices", "users", on_delete: :restrict
  add_foreign_key "seat_audit_events", "event_seats", on_delete: :restrict
  add_foreign_key "seat_audit_events", "events", on_delete: :restrict
  add_foreign_key "seat_audit_events", "seat_hold_sessions", on_delete: :restrict
  add_foreign_key "seat_audit_events", "tickets", on_delete: :restrict
  add_foreign_key "seat_audit_events", "users", column: "actor_user_id", on_delete: :nullify
  add_foreign_key "seat_hold_sessions", "event_seating_configurations", on_delete: :restrict
  add_foreign_key "seat_hold_sessions", "orders", on_delete: :restrict
  add_foreign_key "seat_hold_sessions", "users", on_delete: :nullify
  add_foreign_key "seat_holds", "event_seats", on_delete: :restrict
  add_foreign_key "seat_holds", "order_items", on_delete: :restrict
  add_foreign_key "seat_holds", "pricing_tiers", on_delete: :restrict
  add_foreign_key "seat_holds", "seat_hold_sessions", on_delete: :restrict
  add_foreign_key "seating_price_zones", "venue_layouts", on_delete: :cascade
  add_foreign_key "seating_rows", "seating_sections", on_delete: :cascade
  add_foreign_key "seating_sections", "venue_layouts", on_delete: :cascade
  add_foreign_key "settlement_items", "settlements", on_delete: :restrict
  add_foreign_key "settlements", "events", on_delete: :restrict
  add_foreign_key "settlements", "organizations", on_delete: :restrict
  add_foreign_key "solid_queue_batch_executions", "solid_queue_batches", column: "batch_id", on_delete: :cascade
  add_foreign_key "solid_queue_batch_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "stripe_fee_evidences", "fee_components"
  add_foreign_key "stripe_fee_evidences", "payments"
  add_foreign_key "support_notes", "events", on_delete: :restrict
  add_foreign_key "support_notes", "orders", on_delete: :restrict
  add_foreign_key "support_notes", "tickets", on_delete: :restrict
  add_foreign_key "support_notes", "users", column: "author_user_id", on_delete: :restrict
  add_foreign_key "ticket_inventory_retentions", "disputes"
  add_foreign_key "ticket_inventory_retentions", "reconciliation_exceptions"
  add_foreign_key "ticket_inventory_retentions", "refunds"
  add_foreign_key "ticket_inventory_retentions", "tickets"
  add_foreign_key "ticket_transfers", "tickets", on_delete: :restrict
  add_foreign_key "ticket_transfers", "users", column: "accepted_by_user_id", on_delete: :restrict
  add_foreign_key "ticket_transfers", "users", column: "initiated_by_user_id", on_delete: :restrict
  add_foreign_key "ticket_type_included_events", "events", column: "included_event_id", on_delete: :restrict
  add_foreign_key "ticket_type_included_events", "ticket_types", on_delete: :cascade
  add_foreign_key "ticket_types", "events"
  add_foreign_key "tickets", "event_seats", on_delete: :restrict
  add_foreign_key "tickets", "events"
  add_foreign_key "tickets", "order_items", on_delete: :restrict
  add_foreign_key "tickets", "orders"
  add_foreign_key "tickets", "pricing_tiers"
  add_foreign_key "tickets", "scanner_devices", column: "last_entry_device_id"
  add_foreign_key "tickets", "ticket_types"
  add_foreign_key "tickets", "tickets", column: "parent_ticket_id", on_delete: :restrict
  add_foreign_key "tickets", "users", column: "holder_user_id", on_delete: :restrict
  add_foreign_key "tin_match_requests", "organizer_tax_informations"
  add_foreign_key "venue_layouts", "organizations", on_delete: :restrict
  add_foreign_key "venue_layouts", "venues", on_delete: :restrict
  add_foreign_key "venue_seats", "seating_price_zones", on_delete: :restrict
  add_foreign_key "venue_seats", "seating_rows", on_delete: :cascade
  add_foreign_key "venue_slug_redirects", "venues"
  add_foreign_key "waitlist_entries", "events"
  add_foreign_key "waitlist_entries", "ticket_types"
  add_foreign_key "waitlist_entries", "users"
  add_foreign_key "waitlist_offers", "events", on_delete: :restrict
  add_foreign_key "waitlist_offers", "orders", on_delete: :restrict
  add_foreign_key "waitlist_offers", "pricing_tiers", on_delete: :restrict
  add_foreign_key "waitlist_offers", "ticket_types", on_delete: :restrict
  add_foreign_key "waitlist_offers", "waitlist_entries", on_delete: :restrict
  add_foreign_key "waiver_acceptances", "event_waivers", on_delete: :restrict
  add_foreign_key "waiver_acceptances", "orders", on_delete: :restrict
  add_foreign_key "wallet_passes", "tickets"
  execute <<~SQL
    CREATE OR REPLACE FUNCTION hafapass_protect_audit_log() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Audit logs cannot be deleted' USING ERRCODE = '23514';
      END IF;
      IF current_setting('hafapass.audit_redaction', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION 'Audit logs are append-only' USING ERRCODE = '23514';
      END IF;
      IF (to_jsonb(NEW) - ARRAY['before_data','after_data','metadata','ip_address','retention_anonymized_at','updated_at'])
          IS DISTINCT FROM
         (to_jsonb(OLD) - ARRAY['before_data','after_data','metadata','ip_address','retention_anonymized_at','updated_at']) THEN
        RAISE EXCEPTION 'Audit identity cannot be redacted' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS audit_logs_append_only ON audit_logs;
    CREATE TRIGGER audit_logs_append_only BEFORE UPDATE OR DELETE ON audit_logs
      FOR EACH ROW EXECUTE FUNCTION hafapass_protect_audit_log();
    CREATE OR REPLACE FUNCTION hafapass_protect_audit_log_truncate() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF current_setting('hafapass.audit_truncate', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION 'Audit logs cannot be truncated' USING ERRCODE = '23514';
      END IF;
      RETURN NULL;
    END;
    $$;
    CREATE OR REPLACE TRIGGER audit_logs_no_truncate BEFORE TRUNCATE ON audit_logs
      FOR EACH STATEMENT EXECUTE FUNCTION hafapass_protect_audit_log_truncate();
  SQL

  execute <<~SQL
    CREATE OR REPLACE FUNCTION hafapass_payment_capture_recorded_at() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      captured boolean := NEW.status IN (1, 4, 5);
    BEGIN
      IF TG_OP = 'UPDATE' AND OLD.capture_recorded_at IS NOT NULL THEN
        IF NEW.capture_recorded_at IS DISTINCT FROM OLD.capture_recorded_at THEN
          RAISE EXCEPTION 'A payment''s capture recording time is set once' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END IF;
      IF captured AND (TG_OP = 'INSERT' OR OLD.status NOT IN (1, 4, 5)) THEN
        NEW.capture_recorded_at := COALESCE(NEW.capture_recorded_at, timezone('UTC', clock_timestamp()));
      ELSIF NEW.capture_recorded_at IS NOT NULL THEN
        RAISE EXCEPTION 'A capture recording time is written only when the payment is first captured'
          USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS payments_capture_recorded_at ON payments;
    CREATE TRIGGER payments_capture_recorded_at BEFORE INSERT OR UPDATE OF status, capture_recorded_at ON payments
      FOR EACH ROW EXECUTE FUNCTION hafapass_payment_capture_recorded_at();
    CREATE OR REPLACE FUNCTION hafapass_append_only() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION '% rows are append-only', TG_TABLE_NAME USING ERRCODE = '23514';
    END;
    $$;
    -- Only the confirmed synthetic-data purge may empty these tables, with the
    -- same transaction-scoped opt-in it sets for audit_logs.
    CREATE OR REPLACE FUNCTION hafapass_append_only_truncate() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF current_setting('hafapass.audit_truncate', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION '% cannot be truncated', TG_TABLE_NAME USING ERRCODE = '23514';
      END IF;
      RETURN NULL;
    END;
    $$;
    DROP TRIGGER IF EXISTS never_fulfilled_captures_append_only ON never_fulfilled_captures;
    CREATE TRIGGER never_fulfilled_captures_append_only BEFORE UPDATE OR DELETE ON never_fulfilled_captures
      FOR EACH ROW EXECUTE FUNCTION hafapass_append_only();
    CREATE OR REPLACE TRIGGER never_fulfilled_captures_no_truncate BEFORE TRUNCATE ON never_fulfilled_captures
      FOR EACH STATEMENT EXECUTE FUNCTION hafapass_append_only_truncate();
    DROP TRIGGER IF EXISTS financial_cutovers_append_only ON financial_cutovers;
    CREATE TRIGGER financial_cutovers_append_only BEFORE UPDATE OR DELETE ON financial_cutovers
      FOR EACH ROW EXECUTE FUNCTION hafapass_append_only();
    CREATE OR REPLACE TRIGGER financial_cutovers_no_truncate BEFORE TRUNCATE ON financial_cutovers
      FOR EACH STATEMENT EXECUTE FUNCTION hafapass_append_only_truncate();
    CREATE OR REPLACE FUNCTION hafapass_check_never_fulfilled_capture() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      ord orders%ROWTYPE;
      pay payments%ROWTYPE;
      cutover timestamp;
    BEGIN
      SELECT * INTO ord FROM orders WHERE id = NEW.order_id FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Classified order does not exist' USING ERRCODE = '23503';
      END IF;
      SELECT * INTO pay FROM payments WHERE id = NEW.payment_id FOR SHARE;
      IF NOT FOUND OR pay.order_id <> NEW.order_id THEN
        RAISE EXCEPTION 'A classified payment must belong to the classified order' USING ERRCODE = '23503';
      END IF;
      IF pay.status NOT IN (1, 4, 5) THEN
        RAISE EXCEPTION 'Only a captured payment can be classified' USING ERRCODE = '23514';
      END IF;
      IF pay.amount_cents <> NEW.captured_cents OR lower(pay.currency) <> lower(NEW.currency) THEN
        RAISE EXCEPTION 'A classification must match its payment''s amount and currency' USING ERRCODE = '23514';
      END IF;

      IF pay.capture_recorded_at IS NOT NULL THEN
        NEW.capture_recorded_at := COALESCE(NEW.capture_recorded_at, pay.capture_recorded_at);
        IF NEW.capture_recorded_at <> pay.capture_recorded_at THEN
          RAISE EXCEPTION 'A classification must use its payment''s recorded capture time' USING ERRCODE = '23514';
        END IF;
      ELSE
        SELECT recorded_at INTO cutover FROM financial_cutovers WHERE key = 'a1_capture_recording';
        IF NEW.provenance <> 'backfill' OR NEW.capture_recorded_at IS NULL OR cutover IS NULL
            OR NEW.capture_recorded_at > cutover THEN
          RAISE EXCEPTION 'A capture recorded before A1 needs a backfilled time with evidence, no later than the cutover'
            USING ERRCODE = '23514';
        END IF;
      END IF;

      IF NEW.capture_scope = 'order' THEN
        IF ord.completed_at IS NOT NULL OR ord.status IN (0, 1) OR ord.fulfilled_by_payment_id IS NOT NULL
            OR EXISTS (SELECT 1 FROM audit_logs WHERE action = 'order.completed'
              AND deduplication_key = 'order:' || ord.id || ':completed') THEN
          RAISE EXCEPTION 'A pending or fulfilled order cannot be classified as never fulfilled' USING ERRCODE = '23514';
        END IF;
        IF EXISTS (SELECT 1 FROM tickets WHERE order_id = NEW.order_id AND status <> 2) THEN
          RAISE EXCEPTION 'An order with active tickets cannot be classified as never fulfilled' USING ERRCODE = '23514';
        END IF;
      ELSE
        IF ord.fulfilled_by_payment_id IS NULL THEN
          RAISE EXCEPTION 'A second capture needs the order''s verified fulfilling payment' USING ERRCODE = '23514';
        END IF;
        IF ord.fulfilled_by_payment_id = NEW.payment_id THEN
          RAISE EXCEPTION 'The fulfilling payment cannot be classified as never fulfilled' USING ERRCODE = '23514';
        END IF;
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS never_fulfilled_captures_check ON never_fulfilled_captures;
    CREATE TRIGGER never_fulfilled_captures_check BEFORE INSERT ON never_fulfilled_captures
      FOR EACH ROW EXECUTE FUNCTION hafapass_check_never_fulfilled_capture();

    -- The order marker is derived from its first order-scope row, never written directly.
    CREATE OR REPLACE FUNCTION hafapass_mark_never_fulfilled_order() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.capture_scope = 'order' THEN
        UPDATE orders SET never_fulfilled_at = NEW.created_at WHERE id = NEW.order_id AND never_fulfilled_at IS NULL;
      END IF;
      RETURN NULL;
    END;
    $$;
    DROP TRIGGER IF EXISTS never_fulfilled_captures_mark_order ON never_fulfilled_captures;
    CREATE TRIGGER never_fulfilled_captures_mark_order AFTER INSERT ON never_fulfilled_captures
      FOR EACH ROW EXECUTE FUNCTION hafapass_mark_never_fulfilled_order();
    CREATE OR REPLACE FUNCTION hafapass_guard_order_fulfillment() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      payment_status integer;
    BEGIN
      IF TG_OP = 'INSERT' THEN
        IF NEW.never_fulfilled_at IS NOT NULL OR NEW.fulfilled_by_payment_id IS NOT NULL THEN
          RAISE EXCEPTION 'An order''s fulfilment is recorded by its lifecycle, not at creation' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END IF;

      IF NEW.never_fulfilled_at IS DISTINCT FROM OLD.never_fulfilled_at THEN
        IF OLD.never_fulfilled_at IS NOT NULL THEN
          RAISE EXCEPTION 'An order''s never-fulfilled marker is set once' USING ERRCODE = '23514';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM never_fulfilled_captures WHERE order_id = NEW.id AND capture_scope = 'order'
            AND created_at = NEW.never_fulfilled_at) THEN
          RAISE EXCEPTION 'The never-fulfilled marker comes only from an order-scope classification' USING ERRCODE = '23514';
        END IF;
      END IF;

      IF NEW.fulfilled_by_payment_id IS DISTINCT FROM OLD.fulfilled_by_payment_id THEN
        IF OLD.fulfilled_by_payment_id IS NOT NULL THEN
          RAISE EXCEPTION 'An order''s fulfilling payment is set once' USING ERRCODE = '23514';
        END IF;
        IF NEW.status NOT IN (1, 2, 4) THEN
          RAISE EXCEPTION 'Only a fulfilled order records its fulfilling payment' USING ERRCODE = '23514';
        END IF;
        SELECT status INTO payment_status FROM payments
          WHERE id = NEW.fulfilled_by_payment_id AND order_id = NEW.id FOR KEY SHARE;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'The fulfilling payment must belong to this order' USING ERRCODE = '23503';
        END IF;
        IF payment_status NOT IN (1, 4, 5) THEN
          RAISE EXCEPTION 'The fulfilling payment must be captured' USING ERRCODE = '23514';
        END IF;
        IF EXISTS (SELECT 1 FROM never_fulfilled_captures WHERE payment_id = NEW.fulfilled_by_payment_id
            OR (order_id = NEW.id AND capture_scope = 'order')) THEN
          RAISE EXCEPTION 'A never-fulfilled payment or order cannot record a fulfilling payment' USING ERRCODE = '23514';
        END IF;
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS orders_fulfillment_guard ON orders;
    CREATE TRIGGER orders_fulfillment_guard BEFORE INSERT OR UPDATE OF never_fulfilled_at, fulfilled_by_payment_id ON orders
      FOR EACH ROW EXECUTE FUNCTION hafapass_guard_order_fulfillment();
    CREATE OR REPLACE FUNCTION hafapass_guard_ticket_issuance() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.status = 2 THEN
        RETURN NEW;
      END IF;
      IF TG_OP = 'UPDATE' AND OLD.status <> 2 AND OLD.order_id = NEW.order_id THEN
        RETURN NEW;
      END IF;
      IF TG_OP = 'INSERT' THEN
        PERFORM 1 FROM orders WHERE id = NEW.order_id FOR KEY SHARE;
      ELSE
        BEGIN
          PERFORM 1 FROM orders WHERE id = NEW.order_id FOR KEY SHARE NOWAIT;
        EXCEPTION WHEN lock_not_available THEN
          RAISE EXCEPTION 'Lock the order before reactivating or reassigning a ticket' USING ERRCODE = '55P03';
        END;
      END IF;
      IF EXISTS (SELECT 1 FROM orders WHERE id = NEW.order_id AND never_fulfilled_at IS NOT NULL)
          OR EXISTS (SELECT 1 FROM never_fulfilled_captures WHERE order_id = NEW.order_id AND capture_scope = 'order') THEN
        RAISE EXCEPTION 'Tickets cannot be issued on a never-fulfilled order' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS tickets_issuance_guard ON tickets;
    CREATE TRIGGER tickets_issuance_guard BEFORE INSERT OR UPDATE OF order_id, status ON tickets
      FOR EACH ROW EXECUTE FUNCTION hafapass_guard_ticket_issuance();
    CREATE OR REPLACE FUNCTION hafapass_refund_success_recorded_at() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'UPDATE' AND OLD.success_recorded_at IS NOT NULL THEN
        IF NEW.success_recorded_at IS DISTINCT FROM OLD.success_recorded_at THEN
          RAISE EXCEPTION 'A refund''s success recording time is set once' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END IF;
      IF NEW.success_recorded_at IS NOT NULL THEN
        RAISE EXCEPTION 'A refund''s success recording time is written by the database' USING ERRCODE = '23514';
      END IF;
      IF NEW.status = 1 AND (TG_OP = 'INSERT' OR OLD.status <> 1) THEN
        NEW.success_recorded_at := timezone('UTC', clock_timestamp());
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS refunds_success_recorded_at ON refunds;
    CREATE TRIGGER refunds_success_recorded_at BEFORE INSERT OR UPDATE OF status, success_recorded_at ON refunds
      FOR EACH ROW EXECUTE FUNCTION hafapass_refund_success_recorded_at();

    -- loss_reversed_at: the application asks for it by writing any value on a
    -- lost dispute; the database replaces it with its own time, once.
    CREATE OR REPLACE FUNCTION hafapass_dispute_recorded_at() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'UPDATE' AND OLD.loss_recorded_at IS NOT NULL THEN
        IF NEW.loss_recorded_at IS DISTINCT FROM OLD.loss_recorded_at THEN
          RAISE EXCEPTION 'A dispute''s loss recording time is set once' USING ERRCODE = '23514';
        END IF;
      ELSIF NEW.loss_recorded_at IS NOT NULL THEN
        RAISE EXCEPTION 'A dispute''s loss recording time is written by the database' USING ERRCODE = '23514';
      ELSIF NEW.status = 2 AND (TG_OP = 'INSERT' OR OLD.status <> 2) THEN
        NEW.loss_recorded_at := timezone('UTC', clock_timestamp());
      END IF;

      IF TG_OP = 'INSERT' THEN
        IF NEW.loss_reversed_at IS NOT NULL THEN
          RAISE EXCEPTION 'A dispute loss is reversed only after it was recorded' USING ERRCODE = '23514';
        END IF;
      ELSIF OLD.loss_reversed_at IS NOT NULL THEN
        IF NEW.loss_reversed_at IS DISTINCT FROM OLD.loss_reversed_at OR NEW.status <> 2 THEN
          RAISE EXCEPTION 'A reversed dispute loss is final' USING ERRCODE = '23514';
        END IF;
      ELSIF NEW.loss_reversed_at IS NOT NULL THEN
        IF OLD.status <> 2 OR NEW.status <> 2 THEN
          RAISE EXCEPTION 'Only a recorded dispute loss can be reversed' USING ERRCODE = '23514';
        END IF;
        NEW.loss_reversed_at := timezone('UTC', clock_timestamp());
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS disputes_recorded_at ON disputes;
    CREATE TRIGGER disputes_recorded_at BEFORE INSERT OR UPDATE OF status, loss_recorded_at, loss_reversed_at ON disputes
      FOR EACH ROW EXECUTE FUNCTION hafapass_dispute_recorded_at();
    CREATE OR REPLACE FUNCTION hafapass_check_buyer_return_posting() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      cap never_fulfilled_captures%ROWTYPE;
      src_payment bigint;
      src_amount integer;
      src_currency text;
      src_status integer;
      stamp timestamp;
      cutover timestamp;
      reversed buyer_return_postings%ROWTYPE;
      prev_sequence integer;
      prev_applied bigint;
      prev_proceeds bigint;
      prev_fee bigint;
      prev_organizer_fee bigint;
      prev_tax bigint;
    BEGIN
      SELECT * INTO cap FROM never_fulfilled_captures WHERE id = NEW.never_fulfilled_capture_id;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'A return posting needs its classified capture' USING ERRCODE = '23503';
      END IF;
      PERFORM 1 FROM orders WHERE id = cap.order_id FOR UPDATE;

      NEW.capture_recorded_at := COALESCE(NEW.capture_recorded_at, cap.capture_recorded_at);
      IF NEW.capture_recorded_at <> cap.capture_recorded_at OR NEW.allocation_policy <> cap.allocation_policy
          OR NEW.policy_version <> cap.policy_version THEN
        RAISE EXCEPTION 'A return posting copies its capture''s recording time and allocation policy' USING ERRCODE = '23514';
      END IF;

      IF NEW.source_type = 'Refund' THEN
        SELECT payment_id, amount_cents, currency, status, success_recorded_at
          INTO src_payment, src_amount, src_currency, src_status, stamp FROM refunds WHERE id = NEW.source_id;
      ELSE
        SELECT payment_id, amount_cents, currency, status,
            CASE WHEN NEW.kind = 'dispute_loss_reversal' THEN loss_reversed_at ELSE loss_recorded_at END
          INTO src_payment, src_amount, src_currency, src_status, stamp FROM disputes WHERE id = NEW.source_id;
      END IF;
      IF NOT FOUND OR src_payment IS DISTINCT FROM cap.payment_id THEN
        RAISE EXCEPTION 'A return posting''s movement must belong to the classified payment' USING ERRCODE = '23503';
      END IF;
      IF lower(src_currency) <> lower(cap.currency) THEN
        RAISE EXCEPTION 'A return posting''s movement must be in the capture''s currency' USING ERRCODE = '23514';
      END IF;

      IF NEW.kind = 'refund' THEN
        IF src_status <> 1 OR NEW.gross_cents <> src_amount THEN
          RAISE EXCEPTION 'A refund posting needs a succeeded refund of the same gross amount' USING ERRCODE = '23514';
        END IF;
      ELSIF NEW.kind = 'dispute_loss' THEN
        IF src_status <> 2 OR NEW.gross_cents <> src_amount THEN
          RAISE EXCEPTION 'A dispute posting needs a lost dispute of the same gross amount' USING ERRCODE = '23514';
        END IF;
      ELSIF NEW.kind = 'dispute_loss_reversal' THEN
        SELECT * INTO reversed FROM buyer_return_postings WHERE id = NEW.reverses_posting_id;
        IF NOT FOUND OR reversed.never_fulfilled_capture_id <> NEW.never_fulfilled_capture_id
            OR reversed.kind <> 'dispute_loss' OR reversed.source_id <> NEW.source_id
            OR src_status <> 2 OR stamp IS NULL OR NEW.gross_cents <> -reversed.gross_cents THEN
          RAISE EXCEPTION 'A loss reversal needs the reversed loss''s posting and a recorded reversal' USING ERRCODE = '23514';
        END IF;
      ELSE
        -- refund_reversal needs an approved finance action, which A1 does not ship.
        RAISE EXCEPTION 'Refund reversals are posted only by an approved finance correction' USING ERRCODE = '23514';
      END IF;

      IF stamp IS NOT NULL THEN
        NEW.recorded_at := COALESCE(NEW.recorded_at, stamp);
        IF NEW.recorded_at <> stamp OR NEW.recording_source <> 'database' THEN
          RAISE EXCEPTION 'A return posting uses its movement''s database recording time' USING ERRCODE = '23514';
        END IF;
      ELSE
        SELECT recorded_at INTO cutover FROM financial_cutovers WHERE key = 'a1_return_recording';
        IF NEW.recording_source <> 'backfill' OR NEW.recorded_at IS NULL OR cutover IS NULL
            OR NEW.recorded_at > cutover OR NEW.evidence = '{}'::jsonb THEN
          RAISE EXCEPTION 'A movement recorded before A1 needs a backfilled time with evidence, no later than the cutover'
            USING ERRCODE = '23514';
        END IF;
      END IF;
      NEW.recognized_at := COALESCE(NEW.recognized_at, GREATEST(NEW.recorded_at, NEW.capture_recorded_at));

      SELECT COALESCE(MAX(sequence), 0), COALESCE(SUM(applied_cents), 0), COALESCE(SUM(proceeds_cents), 0),
          COALESCE(SUM(fee_cents), 0), COALESCE(SUM(organizer_fee_cents), 0), COALESCE(SUM(tax_cents), 0)
        INTO prev_sequence, prev_applied, prev_proceeds, prev_fee, prev_organizer_fee, prev_tax
        FROM buyer_return_postings WHERE never_fulfilled_capture_id = NEW.never_fulfilled_capture_id;
      IF NEW.sequence <> prev_sequence + 1 THEN
        RAISE EXCEPTION 'Return postings are sequenced 1, 2, ... per capture' USING ERRCODE = '23514';
      END IF;
      -- Excess is decided on gross against the captured amount alone.
      IF NEW.kind IN ('refund', 'dispute_loss') AND NEW.applied_cents <> LEAST(NEW.gross_cents, cap.captured_cents - prev_applied) THEN
        RAISE EXCEPTION 'A return applies the smaller of its gross and the amount still owed' USING ERRCODE = '23514';
      END IF;
      IF prev_applied + NEW.applied_cents NOT BETWEEN 0 AND cap.captured_cents
          OR prev_proceeds + NEW.proceeds_cents NOT BETWEEN 0 AND cap.proceeds_cents
          OR prev_fee + NEW.fee_cents NOT BETWEEN 0 AND cap.fee_cents
          OR prev_organizer_fee + NEW.organizer_fee_cents NOT BETWEEN 0 AND cap.organizer_fee_cents
          OR prev_tax + NEW.tax_cents NOT BETWEEN 0 AND cap.tax_cents THEN
        RAISE EXCEPTION 'Cumulative returned shares must stay within the capture''s components' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS buyer_return_postings_check ON buyer_return_postings;
    CREATE TRIGGER buyer_return_postings_check BEFORE INSERT ON buyer_return_postings
      FOR EACH ROW EXECUTE FUNCTION hafapass_check_buyer_return_posting();
    DROP TRIGGER IF EXISTS buyer_return_postings_append_only ON buyer_return_postings;
    CREATE TRIGGER buyer_return_postings_append_only BEFORE UPDATE OR DELETE ON buyer_return_postings
      FOR EACH ROW EXECUTE FUNCTION hafapass_append_only();
    CREATE OR REPLACE TRIGGER buyer_return_postings_no_truncate BEFORE TRUNCATE ON buyer_return_postings
      FOR EACH STATEMENT EXECUTE FUNCTION hafapass_append_only_truncate();
    CREATE OR REPLACE FUNCTION hafapass_fenced_payment(target bigint) RETURNS boolean
    LANGUAGE sql STABLE AS $$
      SELECT target IS NOT NULL AND (
        EXISTS (SELECT 1 FROM never_fulfilled_captures WHERE payment_id = target)
        OR EXISTS (SELECT 1 FROM reconciliation_exceptions WHERE payment_id = target
          AND code IN ('late_payment_success_after_inventory_release', 'late_payment_success_after_hold_expiry', 'pass_all_included_nights_cancelled', 'unfulfilled_second_capture', 'never_fulfilled_ownership_ambiguous', 'never_fulfilled_classification_quarantined')))
    $$;

    -- Identity is append-only; state moves forward only. Operation n > 1 is
    -- reserved only after every earlier operation reached a verified
    -- terminal state, so a retry is never a new operation (design §6.3).
    CREATE OR REPLACE FUNCTION hafapass_check_repayment_operation() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      cap never_fulfilled_captures%ROWTYPE;
      last_sequence integer;
      expected_key text;
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Repayment operations are append-only' USING ERRCODE = '23514';
      END IF;
      IF TG_OP = 'INSERT' THEN
        SELECT * INTO cap FROM never_fulfilled_captures WHERE id = NEW.never_fulfilled_capture_id;
        IF NOT FOUND OR cap.payment_id <> NEW.payment_id OR cap.currency <> NEW.currency THEN
          RAISE EXCEPTION 'A repayment operation belongs to its classified payment' USING ERRCODE = '23514';
        END IF;
        PERFORM 1 FROM orders WHERE id = cap.order_id FOR UPDATE;
        SELECT COALESCE(MAX(sequence), 0) INTO last_sequence FROM repayment_operations
          WHERE never_fulfilled_capture_id = NEW.never_fulfilled_capture_id;
        IF NEW.sequence <> last_sequence + 1 THEN
          RAISE EXCEPTION 'Repayment operations are numbered contiguously' USING ERRCODE = '23514';
        END IF;
        -- Each reserved operation has its own key; only an adopted legacy
        -- first operation keeps the older release's key.
        expected_key := 'late-capture:payment:' || NEW.payment_id ||
          CASE WHEN NEW.adopted THEN '' ELSE ':op:' || NEW.sequence END;
        IF NEW.idempotency_key <> expected_key THEN
          RAISE EXCEPTION 'Repayment operation % must use key %', NEW.sequence, expected_key USING ERRCODE = '23514';
        END IF;
        IF EXISTS (SELECT 1 FROM repayment_operations WHERE never_fulfilled_capture_id = NEW.never_fulfilled_capture_id
            AND state NOT IN ('succeeded', 'failed_terminal')) THEN
          RAISE EXCEPTION 'A new repayment operation waits until earlier ones are verified' USING ERRCODE = '23514';
        END IF;
        IF NOT NEW.adopted AND (NEW.state <> 'reserved' OR NEW.refund_id IS NOT NULL OR NEW.submission_count <> 0) THEN
          RAISE EXCEPTION 'A new repayment operation starts reserved' USING ERRCODE = '23514';
        END IF;
        IF NEW.adopted AND (NEW.sequence <> 1 OR NEW.refund_id IS NULL) THEN
          RAISE EXCEPTION 'Only the legacy first operation is adopted, with its refund' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END IF;

      IF (NEW.never_fulfilled_capture_id, NEW.payment_id, NEW.sequence, NEW.amount_cents, NEW.currency,
          NEW.idempotency_key, NEW.source, NEW.adopted, NEW.created_at) IS DISTINCT FROM
         (OLD.never_fulfilled_capture_id, OLD.payment_id, OLD.sequence, OLD.amount_cents, OLD.currency,
          OLD.idempotency_key, OLD.source, OLD.adopted, OLD.created_at) THEN
        RAISE EXCEPTION 'A repayment operation''s identity is immutable' USING ERRCODE = '23514';
      END IF;
      IF OLD.refund_id IS NOT NULL AND NEW.refund_id IS DISTINCT FROM OLD.refund_id THEN
        RAISE EXCEPTION 'A repayment operation''s refund is set once' USING ERRCODE = '23514';
      END IF;
      IF NEW.submission_count < OLD.submission_count THEN
        RAISE EXCEPTION 'Submission counts never decrease' USING ERRCODE = '23514';
      END IF;
      IF OLD.state IN ('succeeded', 'failed_terminal') AND NEW.state IS DISTINCT FROM OLD.state THEN
        RAISE EXCEPTION 'A verified repayment outcome is final' USING ERRCODE = '23514';
      END IF;
      IF NEW.state IS DISTINCT FROM OLD.state AND NOT (
          -- reserved -> succeeded records a provider fact that arrived without
          -- this operation's own send; it is never refused, and is audited.
          (OLD.state = 'reserved' AND NEW.state IN ('submitting', 'failed_terminal', 'succeeded')) OR
          (OLD.state = 'submitting' AND NEW.state IN ('unknown', 'succeeded', 'failed_terminal')) OR
          (OLD.state = 'unknown' AND NEW.state IN ('submitting', 'succeeded', 'failed_terminal'))) THEN
        RAISE EXCEPTION 'Repayment operation cannot move from % to %', OLD.state, NEW.state USING ERRCODE = '23514';
      END IF;
      -- Only the gate sends, and each send is counted once: entering
      -- "submitting", or re-sending a stale "submitting" after the in-flight
      -- bound, adds exactly one.
      IF NEW.state = 'submitting' AND OLD.state <> 'submitting' AND NEW.submission_count <> OLD.submission_count + 1 THEN
        RAISE EXCEPTION 'Each submission is counted once' USING ERRCODE = '23514';
      END IF;
      IF NEW.submission_count <> OLD.submission_count AND
          (NEW.state <> 'submitting' OR NEW.submission_count <> OLD.submission_count + 1) THEN
        RAISE EXCEPTION 'Submissions are counted only by the gate, one at a time' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS repayment_operations_check ON repayment_operations;
    CREATE TRIGGER repayment_operations_check BEFORE INSERT OR UPDATE OR DELETE ON repayment_operations
      FOR EACH ROW EXECUTE FUNCTION hafapass_check_repayment_operation();
    CREATE OR REPLACE TRIGGER repayment_operations_no_truncate BEFORE TRUNCATE ON repayment_operations
      FOR EACH STATEMENT EXECUTE FUNCTION hafapass_append_only_truncate();

    CREATE OR REPLACE FUNCTION hafapass_refund_repayment_fence() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      op repayment_operations%ROWTYPE;
      inbound boolean;
    BEGIN
      IF NEW.repayment_operation_id IS NOT NULL AND
          (TG_OP = 'INSERT' OR NEW.repayment_operation_id IS DISTINCT FROM OLD.repayment_operation_id) THEN
        IF TG_OP = 'UPDATE' AND OLD.repayment_operation_id IS NOT NULL THEN
          RAISE EXCEPTION 'A refund''s repayment operation is set once' USING ERRCODE = '23514';
        END IF;
        SELECT * INTO op FROM repayment_operations WHERE id = NEW.repayment_operation_id;
        IF NOT FOUND OR op.payment_id IS DISTINCT FROM NEW.payment_id OR op.idempotency_key <> NEW.idempotency_key
            OR op.amount_cents <> NEW.amount_cents OR op.currency <> NEW.currency THEN
          RAISE EXCEPTION 'A refund matches its repayment operation exactly' USING ERRCODE = '23514';
        END IF;
      ELSIF TG_OP = 'UPDATE' AND OLD.repayment_operation_id IS NOT NULL AND NEW.repayment_operation_id IS NULL THEN
        RAISE EXCEPTION 'A refund''s repayment operation is set once' USING ERRCODE = '23514';
      END IF;

      IF NOT hafapass_fenced_payment(NEW.payment_id) THEN
        RETURN NEW;
      END IF;
      -- Provider evidence passes only when positively identified: a row that
      -- carries the provider's refund ID, or the insert of an inbound record
      -- (provider:stripe:refund:<id>), which never reaches the gate.
      IF NEW.provider_refund_id IS NOT NULL THEN
        RETURN NEW;
      END IF;
      inbound := NEW.idempotency_key LIKE 'provider:stripe:refund:%';
      IF TG_OP = 'INSERT' AND inbound THEN
        RETURN NEW;
      END IF;
      IF TG_OP = 'INSERT' AND NEW.repayment_operation_id IS NULL THEN
        RAISE EXCEPTION 'Repayment fence: this payment is returned only through a repayment operation'
          USING ERRCODE = '23514';
      END IF;
      IF NEW.failure_code = 'provider_result_unknown' AND
          (TG_OP = 'INSERT' OR OLD.failure_code IS DISTINCT FROM 'provider_result_unknown') THEN
        IF NEW.repayment_operation_id IS NULL THEN
          RAISE EXCEPTION 'Repayment fence: this refund cannot be submitted' USING ERRCODE = '23514';
        END IF;
        SELECT * INTO op FROM repayment_operations WHERE id = NEW.repayment_operation_id;
        IF op.state <> 'submitting' THEN
          RAISE EXCEPTION 'Repayment fence: only the operation gate submits this refund' USING ERRCODE = '23514';
        END IF;
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS refunds_repayment_fence ON refunds;
    CREATE TRIGGER refunds_repayment_fence BEFORE INSERT OR UPDATE OF failure_code, repayment_operation_id, provider_refund_id ON refunds
      FOR EACH ROW EXECUTE FUNCTION hafapass_refund_repayment_fence();

    -- P10 strict for every payout writer, old or new: no payout on an event
    -- with an open never-fulfilled item is created, released from hold or
    -- submitted. Holding, failing, reversing and recording a transfer that
    -- already left are not refused here (the application guards paid
    -- recording with the existing queue rule).
    CREATE OR REPLACE FUNCTION hafapass_payout_repayment_fence() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.status NOT IN (0, 1) OR
          (TG_OP = 'UPDATE' AND NEW.status = OLD.status) THEN
        RETURN NEW;
      END IF;
      IF EXISTS (SELECT 1 FROM reconciliation_exceptions re
          WHERE re.status = 0 AND re.code IN ('late_payment_success_after_inventory_release', 'late_payment_success_after_hold_expiry', 'pass_all_included_nights_cancelled', 'unfulfilled_second_capture', 'never_fulfilled_ownership_ambiguous', 'never_fulfilled_classification_quarantined', 'never_fulfilled_return_quarantined', 'never_fulfilled_backfill_ambiguous', 'never_fulfilled_backfill_restatement', 'never_fulfilled_repayment_reopened', 'never_fulfilled_sale_effects_held')
            AND (re.order_id IN (SELECT id FROM orders WHERE event_id = NEW.event_id)
              OR re.payment_id IN (SELECT p.id FROM payments p JOIN orders o ON o.id = p.order_id
                WHERE o.event_id = NEW.event_id))) THEN
        RAISE EXCEPTION 'Repayment fence: a buyer repayment on this event is unresolved' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS payouts_repayment_fence ON payouts;
    CREATE TRIGGER payouts_repayment_fence BEFORE INSERT OR UPDATE OF status ON payouts
      FOR EACH ROW EXECUTE FUNCTION hafapass_payout_repayment_fence();
    -- The payment that may change the sale's items, tickets and commission:
    -- the order's recorded fulfilling payment; an order-scope never-
    -- fulfilled capture (there is no sale to damage); or, with no fulfilling
    -- payment recorded, the order's only captured payment of its mode, and
    -- for a fenced payment only when the order was never fulfilled.
    -- Payment.live_or_legacy_capture's mode rule: a test or simulated
    -- capture never competes with a live one for the same sale.
    CREATE OR REPLACE FUNCTION hafapass_live_or_legacy(environment text, payload jsonb) RETURNS boolean
    LANGUAGE sql IMMUTABLE AS $$
      SELECT COALESCE(environment = 'live', false) OR (environment IS NULL
        AND payload->>'livemode' IS DISTINCT FROM 'false' AND payload->>'simulated' IS DISTINCT FROM 'true')
    $$;

    CREATE OR REPLACE FUNCTION hafapass_sale_owner_payment(target bigint) RETURNS boolean
    LANGUAGE sql STABLE AS $$
      SELECT COALESCE((
        SELECT CASE
          WHEN o.fulfilled_by_payment_id IS NOT NULL THEN o.fulfilled_by_payment_id = p.id
          WHEN EXISTS (SELECT 1 FROM never_fulfilled_captures c WHERE c.payment_id = p.id AND c.capture_scope = 'order')
            THEN true
          ELSE NOT EXISTS (SELECT 1 FROM payments other WHERE other.order_id = p.order_id AND other.id <> p.id
              AND other.status IN (1, 4, 5)
              AND hafapass_live_or_legacy(other.provider_environment, other.provider_payload)
                = hafapass_live_or_legacy(p.provider_environment, p.provider_payload))
            AND (NOT hafapass_fenced_payment(p.id) OR (o.completed_at IS NULL
              AND NOT EXISTS (SELECT 1 FROM tickets t WHERE t.order_id = o.id AND t.status <> 2)))
        END
        FROM payments p JOIN orders o ON o.id = p.order_id WHERE p.id = target), false)
    $$;

    CREATE OR REPLACE FUNCTION hafapass_sale_effect_guard() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      origin_payment bigint;
    BEGIN
      IF TG_TABLE_NAME = 'tickets' THEN
        IF NOT EXISTS (SELECT 1 FROM disputes d WHERE d.order_id = NEW.order_id AND d.status = 2
            AND (d.payment_id IS NULL OR hafapass_sale_owner_payment(d.payment_id))) THEN
          RAISE EXCEPTION 'Sale ownership: a lost dispute on another payment cannot cancel this order''s tickets'
            USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END IF;
      IF NEW.refund_id IS NOT NULL THEN
        SELECT payment_id INTO origin_payment FROM refunds WHERE id = NEW.refund_id;
      ELSIF TG_TABLE_NAME = 'ticket_inventory_retentions' THEN
        SELECT payment_id INTO origin_payment FROM disputes WHERE id = NEW.dispute_id;
      END IF;
      IF origin_payment IS NOT NULL AND NOT hafapass_sale_owner_payment(origin_payment) THEN
        RAISE EXCEPTION 'Sale ownership: payment % does not own this sale', origin_payment USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS refund_items_sale_ownership ON refund_items;
    CREATE TRIGGER refund_items_sale_ownership BEFORE INSERT ON refund_items
      FOR EACH ROW EXECUTE FUNCTION hafapass_sale_effect_guard();
    DROP TRIGGER IF EXISTS promoter_commission_entries_sale_ownership ON promoter_commission_entries;
    CREATE TRIGGER promoter_commission_entries_sale_ownership BEFORE INSERT ON promoter_commission_entries
      FOR EACH ROW WHEN (NEW.refund_id IS NOT NULL) EXECUTE FUNCTION hafapass_sale_effect_guard();
    DROP TRIGGER IF EXISTS ticket_inventory_retentions_sale_ownership ON ticket_inventory_retentions;
    CREATE TRIGGER ticket_inventory_retentions_sale_ownership BEFORE INSERT ON ticket_inventory_retentions
      FOR EACH ROW EXECUTE FUNCTION hafapass_sale_effect_guard();
    DROP TRIGGER IF EXISTS tickets_dispute_sale_ownership ON tickets;
    CREATE TRIGGER tickets_dispute_sale_ownership BEFORE UPDATE OF status ON tickets
      FOR EACH ROW WHEN (NEW.status = 2 AND OLD.status IS DISTINCT FROM NEW.status
        AND NEW.cancellation_reason = 'payment_dispute_lost')
      EXECUTE FUNCTION hafapass_sale_effect_guard();

    -- When the event's earliest open blocking never-fulfilled item opened,
    -- or NULL when nothing blocks it.
    CREATE OR REPLACE FUNCTION hafapass_payout_block_start(target_event bigint) RETURNS timestamp
    LANGUAGE sql STABLE AS $$
      SELECT MIN(re.created_at) FROM reconciliation_exceptions re
        WHERE re.status = 0 AND re.code IN ('late_payment_success_after_inventory_release', 'late_payment_success_after_hold_expiry', 'pass_all_included_nights_cancelled', 'unfulfilled_second_capture', 'never_fulfilled_ownership_ambiguous', 'never_fulfilled_classification_quarantined', 'never_fulfilled_return_quarantined', 'never_fulfilled_backfill_ambiguous', 'never_fulfilled_backfill_restatement', 'never_fulfilled_repayment_reopened', 'never_fulfilled_sale_effects_held')
          AND (re.order_id IN (SELECT id FROM orders WHERE event_id = target_event)
            OR re.payment_id IN (SELECT p.id FROM payments p JOIN orders o ON o.id = p.order_id
              WHERE o.event_id = target_event))
    $$;

    -- An event whose never-fulfilled order is in a status the 7bcd97c2
    -- settlement reader counts as a sale (completed, refunded or partially
    -- refunded). That reader would pay the organizer its proceeds, so only a
    -- reader that excludes them (this release's Settlements::Finalizer and
    -- PayoutCreator, which name themselves in hafapass.settlement_reader)
    -- may finalize its statement or create a payout on it. This keeps the
    -- fence across a rollback until the A2 readers (A1-R1 review finding 2).
    CREATE OR REPLACE FUNCTION hafapass_settlement_reader_required(target_event bigint) RETURNS boolean
    LANGUAGE sql STABLE AS $$
      SELECT EXISTS (SELECT 1 FROM orders o WHERE o.event_id = target_event AND o.never_fulfilled_at IS NOT NULL
          AND o.status IN (1, 2, 4))
        AND current_setting('hafapass.settlement_reader', true) IS DISTINCT FROM 'nfc-a1r1'
    $$;

    -- P10 strict for every payout writer, old or new. Refused on an event
    -- with an open blocking item: creating a payout; releasing a held one;
    -- and moving one to processing or paid, unless its submission was
    -- authorized before the earliest open item. That is the outcome of a
    -- request already sent (or money that already left), recorded with its
    -- evidence, never a new payment. Holding, failing and reversing are
    -- never refused.
    CREATE OR REPLACE FUNCTION hafapass_payout_repayment_fence() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      block_start timestamp;
    BEGIN
      IF TG_OP = 'INSERT' AND hafapass_settlement_reader_required(NEW.event_id) THEN
        RAISE EXCEPTION 'Repayment fence: this event''s payouts need the never-fulfilled settlement reader'
          USING ERRCODE = '23514';
      END IF;
      IF NEW.status NOT IN (0, 1, 2) OR
          (TG_OP = 'UPDATE' AND NEW.status = OLD.status) THEN
        RETURN NEW;
      END IF;
      block_start := hafapass_payout_block_start(NEW.event_id);
      IF block_start IS NULL THEN
        RETURN NEW;
      END IF;
      IF TG_OP = 'UPDATE' AND ((NEW.status = 1 AND OLD.status = 0)
            OR (NEW.status = 2 AND OLD.status IN (0, 1, 5)))
          AND EXISTS (SELECT 1 FROM audit_logs a
          WHERE a.auditable_type = 'Payout' AND a.auditable_id = NEW.id AND a.action = 'payout.submission_requested'
            AND a.occurred_at < block_start) THEN
        RETURN NEW;
      END IF;
      RAISE EXCEPTION 'Repayment fence: a buyer repayment on this event is unresolved' USING ERRCODE = '23514';
    END;
    $$;
    DROP TRIGGER IF EXISTS payouts_repayment_fence ON payouts;
    CREATE TRIGGER payouts_repayment_fence BEFORE INSERT OR UPDATE OF status ON payouts
      FOR EACH ROW EXECUTE FUNCTION hafapass_payout_repayment_fence();

    -- The actual submission authorization of both releases is this audit
    -- row, written under the payout lock before the gateway call; a pending
    -- payout is submitted without a status change.
    CREATE OR REPLACE FUNCTION hafapass_payout_submission_fence() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF hafapass_payout_block_start((SELECT event_id FROM payouts WHERE id = NEW.auditable_id)) IS NOT NULL THEN
        RAISE EXCEPTION 'Repayment fence: a buyer repayment on this event is unresolved' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS audit_logs_payout_submission_fence ON audit_logs;
    CREATE TRIGGER audit_logs_payout_submission_fence BEFORE INSERT ON audit_logs
      FOR EACH ROW WHEN (NEW.action = 'payout.submission_requested' AND NEW.auditable_type = 'Payout')
      EXECUTE FUNCTION hafapass_payout_submission_fence();

    CREATE OR REPLACE FUNCTION hafapass_settlement_finalization_fence() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF hafapass_payout_block_start(NEW.event_id) IS NOT NULL THEN
        RAISE EXCEPTION 'Repayment fence: a buyer repayment on this event is unresolved' USING ERRCODE = '23514';
      END IF;
      IF hafapass_settlement_reader_required(NEW.event_id) THEN
        RAISE EXCEPTION 'Repayment fence: this event''s statement needs the never-fulfilled settlement reader'
          USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS settlements_finalization_fence ON settlements;
    CREATE TRIGGER settlements_finalization_fence BEFORE INSERT OR UPDATE OF status ON settlements
      FOR EACH ROW WHEN (NEW.status = 1)
      EXECUTE FUNCTION hafapass_settlement_finalization_fence();

    CREATE OR REPLACE FUNCTION hafapass_evidence_hold_guard() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF current_setting('hafapass.evidence_resolution', true) IS DISTINCT FROM NEW.id::text THEN
        RAISE EXCEPTION 'Evidence hold: % closes only when its evidence is recorded', NEW.code USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS reconciliation_exceptions_evidence_hold ON reconciliation_exceptions;
    CREATE TRIGGER reconciliation_exceptions_evidence_hold BEFORE UPDATE OF status ON reconciliation_exceptions
      FOR EACH ROW WHEN (OLD.status = 0 AND NEW.status IS DISTINCT FROM OLD.status
        AND NEW.code IN ('unfulfilled_second_capture', 'never_fulfilled_ownership_ambiguous', 'never_fulfilled_classification_quarantined', 'never_fulfilled_return_quarantined', 'never_fulfilled_backfill_ambiguous', 'never_fulfilled_backfill_restatement', 'never_fulfilled_repayment_reopened', 'never_fulfilled_sale_effects_held'))
      EXECUTE FUNCTION hafapass_evidence_hold_guard();

    -- An outbound row of a fenced payment gets a provider refund ID only
    -- from an exact identity (the provider ID or the row's own metadata
    -- key) that the application matched in this transaction. Never from an
    -- amount and date, and never by an older release's writer.
    CREATE OR REPLACE FUNCTION hafapass_refund_identity_fence() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.idempotency_key = 'provider:stripe:refund:' || NEW.provider_refund_id
          OR NOT hafapass_fenced_payment(NEW.payment_id)
          OR current_setting('hafapass.refund_identity', true) IS NOT DISTINCT FROM NEW.id::text THEN
        RETURN NEW;
      END IF;
      RAISE EXCEPTION 'Repayment fence: refund % needs an exact provider identity match', NEW.id USING ERRCODE = '23514';
    END;
    $$;
    DROP TRIGGER IF EXISTS refunds_identity_fence ON refunds;
    CREATE TRIGGER refunds_identity_fence BEFORE UPDATE OF provider_refund_id ON refunds
      FOR EACH ROW WHEN (OLD.provider_refund_id IS NULL AND NEW.provider_refund_id IS NOT NULL)
      EXECUTE FUNCTION hafapass_refund_identity_fence();
    -- What the sale's own payment returned (refunds without a payment are
    -- the sale's: cash and manual returns).
    CREATE OR REPLACE FUNCTION hafapass_sale_refund_total(target_order bigint) RETURNS bigint
    LANGUAGE sql STABLE AS $$
      SELECT COALESCE(SUM(r.amount_cents), 0)::bigint FROM refunds r
        WHERE r.order_id = target_order AND r.status = 1
          AND (r.payment_id IS NULL OR hafapass_sale_owner_payment(r.payment_id))
    $$;

    -- An older release sums every same-mode refund on the order, so a refund
    -- on another payment (B) would count toward the sale paid by A and could
    -- mark it fully refunded, cancel its tickets and release its inventory.
    -- Once the order has such a refund, its refund total may not exceed what
    -- the owning payment returned and it may become refunded only when that
    -- covers the total. Orders whose refunds all come from the sale's own
    -- payment are never affected.
    CREATE OR REPLACE FUNCTION hafapass_guard_order_refund_aggregate() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      owned bigint;
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM refunds r WHERE r.order_id = NEW.id AND r.status = 1
          AND r.payment_id IS NOT NULL AND NOT hafapass_sale_owner_payment(r.payment_id)) THEN
        RETURN NEW;
      END IF;
      owned := LEAST(hafapass_sale_refund_total(NEW.id), NEW.total_cents);
      IF (NEW.refund_amount_cents IS DISTINCT FROM OLD.refund_amount_cents AND NEW.refund_amount_cents > owned)
          OR (NEW.status = 2 AND OLD.status IS DISTINCT FROM NEW.status AND owned < NEW.total_cents) THEN
        RAISE EXCEPTION 'Sale ownership: order % refund total would count another payment''s refunds', NEW.id
          USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS orders_sale_refund_aggregate ON orders;
    CREATE TRIGGER orders_sale_refund_aggregate BEFORE UPDATE OF status, refund_amount_cents ON orders
      FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status OR OLD.refund_amount_cents IS DISTINCT FROM NEW.refund_amount_cents)
      EXECUTE FUNCTION hafapass_guard_order_refund_aggregate();

    -- A real Stripe capture recorded since the A1 capture cutover that no
    -- release classified: on an order another payment fulfilled, or on a sold
    -- order with another capture and no recorded fulfilling payment. 7bcd97c2
    -- acknowledges such a second capture without an exception; this release
    -- classifies or quarantines it (Commerce::NeverFulfilledReconcile).
    CREATE OR REPLACE FUNCTION hafapass_unclassified_capture(target bigint) RETURNS boolean
    LANGUAGE sql STABLE AS $$
      SELECT COALESCE((
        SELECT p.provider = 'stripe' AND p.status IN (1, 4, 5) AND p.capture_recorded_at IS NOT NULL
          AND p.provider_environment IN ('test', 'live') AND p.provider_payment_id IS NOT NULL
          AND NOT starts_with(p.provider_payment_id, 'sim_') AND p.provider_payload->>'simulated' IS DISTINCT FROM 'true'
          AND o.never_fulfilled_at IS NULL
          -- Payment.live_or_legacy_capture's mode rule: a test capture never
          -- competes with a live one for the same sale.
          AND CASE WHEN o.fulfilled_by_payment_id IS NOT NULL THEN o.fulfilled_by_payment_id <> p.id
              AND EXISTS (SELECT 1 FROM payments f WHERE f.id = o.fulfilled_by_payment_id
                AND hafapass_live_or_legacy(f.provider_environment, f.provider_payload)
                  = hafapass_live_or_legacy(p.provider_environment, p.provider_payload))
            ELSE (o.completed_at IS NOT NULL OR o.status IN (1, 2, 4))
              AND EXISTS (SELECT 1 FROM payments other WHERE other.order_id = o.id AND other.id <> p.id
                AND other.status IN (1, 4, 5)
                AND hafapass_live_or_legacy(other.provider_environment, other.provider_payload)
                  = hafapass_live_or_legacy(p.provider_environment, p.provider_payload))
              -- An item on another capture already holds this order.
              AND NOT EXISTS (SELECT 1 FROM reconciliation_exceptions held JOIN payments other ON other.id = held.payment_id
                WHERE other.order_id = o.id AND other.id <> p.id AND held.code IN ('late_payment_success_after_inventory_release', 'late_payment_success_after_hold_expiry', 'pass_all_included_nights_cancelled', 'unfulfilled_second_capture', 'never_fulfilled_ownership_ambiguous', 'never_fulfilled_classification_quarantined', 'never_fulfilled_backfill_ambiguous', 'never_fulfilled_backfill_restatement'))
          END
          AND NOT EXISTS (SELECT 1 FROM never_fulfilled_captures c WHERE c.payment_id = p.id)
          AND NOT EXISTS (SELECT 1 FROM reconciliation_exceptions re WHERE re.payment_id = p.id
            AND re.code IN ('late_payment_success_after_inventory_release', 'late_payment_success_after_hold_expiry', 'pass_all_included_nights_cancelled', 'unfulfilled_second_capture', 'never_fulfilled_ownership_ambiguous', 'never_fulfilled_classification_quarantined', 'never_fulfilled_backfill_ambiguous', 'never_fulfilled_backfill_restatement'))
        FROM payments p JOIN orders o ON o.id = p.order_id WHERE p.id = target), false)
    $$;

    CREATE OR REPLACE FUNCTION hafapass_payout_block_start(target_event bigint) RETURNS timestamp
    LANGUAGE sql STABLE AS $$
      SELECT MIN(started) FROM (
        SELECT re.created_at AS started FROM reconciliation_exceptions re
          WHERE re.status = 0 AND re.code IN ('late_payment_success_after_inventory_release', 'late_payment_success_after_hold_expiry', 'pass_all_included_nights_cancelled', 'unfulfilled_second_capture', 'never_fulfilled_ownership_ambiguous', 'never_fulfilled_classification_quarantined', 'never_fulfilled_return_quarantined', 'never_fulfilled_backfill_ambiguous', 'never_fulfilled_backfill_restatement', 'never_fulfilled_repayment_reopened', 'never_fulfilled_sale_effects_held')
            AND (re.order_id IN (SELECT id FROM orders WHERE event_id = target_event)
              OR re.payment_id IN (SELECT p.id FROM payments p JOIN orders o ON o.id = p.order_id
                WHERE o.event_id = target_event))
        UNION ALL
        SELECT p.capture_recorded_at FROM payments p JOIN orders o ON o.id = p.order_id
          WHERE o.event_id = target_event AND p.capture_recorded_at IS NOT NULL
            AND p.status IN (1, 4, 5) AND hafapass_unclassified_capture(p.id)
      ) blocks
    $$;

    -- P10 strict for every payout writer, old or new. On an event with an
    -- open blocking item: creating a payout, releasing a held one and any
    -- other move to pending, processing or paid is refused, except
    --   pending -> processing: the gateway outcome of a submission
    --     authorized before the earliest open item (a request already sent);
    --   pending, processing or held -> paid: that pre-hold submission, a
    --     transfer time (paid_at) before the earliest open item, and this
    --     release's verified confirmation that the money left before the
    --     hold, named in the same transaction (hafapass.payout_transfer).
    --     A submission authorization does not prove a transfer, and a
    --     timestamp alone proves nothing. 7bcd97c2 never names one.
    -- Holding, failing and reversing are never refused.
    CREATE OR REPLACE FUNCTION hafapass_payout_repayment_fence() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      block_start timestamp;
      submitted_before boolean;
    BEGIN
      IF TG_OP = 'INSERT' AND hafapass_settlement_reader_required(NEW.event_id) THEN
        RAISE EXCEPTION 'Repayment fence: this event''s payouts need the never-fulfilled settlement reader'
          USING ERRCODE = '23514';
      END IF;
      IF NEW.status NOT IN (0, 1, 2) OR
          (TG_OP = 'UPDATE' AND NEW.status = OLD.status) THEN
        RETURN NEW;
      END IF;
      block_start := hafapass_payout_block_start(NEW.event_id);
      IF block_start IS NULL THEN
        RETURN NEW;
      END IF;
      IF TG_OP = 'UPDATE' THEN
        submitted_before := EXISTS (SELECT 1 FROM audit_logs a
          WHERE a.auditable_type = 'Payout' AND a.auditable_id = NEW.id AND a.action = 'payout.submission_requested'
            AND a.occurred_at < block_start);
        IF NEW.status = 1 AND OLD.status = 0 AND submitted_before THEN
          RETURN NEW;
        END IF;
        IF NEW.status = 2
            AND OLD.status IN (0, 1, 5)
            AND submitted_before AND NEW.paid_at IS NOT NULL AND NEW.paid_at < block_start
            AND current_setting('hafapass.payout_transfer', true) IS NOT DISTINCT FROM NEW.id::text THEN
          RETURN NEW;
        END IF;
        IF NEW.status = 2 THEN
          RAISE EXCEPTION 'Repayment fence: payout % needs verified transfer evidence from before the hold', NEW.id
            USING ERRCODE = '23514';
        END IF;
      END IF;
      RAISE EXCEPTION 'Repayment fence: a buyer repayment on this event is unresolved' USING ERRCODE = '23514';
    END;
    $$;
    DROP TRIGGER IF EXISTS payouts_repayment_fence ON payouts;
    CREATE TRIGGER payouts_repayment_fence BEFORE INSERT OR UPDATE OF status ON payouts
      FOR EACH ROW EXECUTE FUNCTION hafapass_payout_repayment_fence();

    -- A signed receipt's provider identity, read from its own payload (the
    -- same fields StripeWebhookProcessor.provider_identity stores). A
    -- capture receipt carries it only when the intent succeeded.
    CREATE OR REPLACE FUNCTION hafapass_keep_receipt_identity() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      object jsonb := OLD.payload -> 'data' -> 'object';
      amount jsonb;
    BEGIN
      IF NEW.provider_payment_intent_id IS NOT NULL OR jsonb_typeof(object) IS DISTINCT FROM 'object'
          OR (OLD.event_type = 'payment_intent.succeeded' AND object->>'status' IS DISTINCT FROM 'succeeded') THEN
        RETURN NEW;
      END IF;
      NEW.provider_payment_intent_id := CASE
        WHEN starts_with(OLD.event_type, 'payment_intent.') THEN NULLIF(object->>'id', '')
        WHEN jsonb_typeof(object->'payment_intent') = 'object' THEN NULLIF(object->'payment_intent'->>'id', '')
        ELSE NULLIF(object->>'payment_intent', '') END;
      IF NEW.provider_payment_intent_id IS NULL THEN
        RETURN NEW;
      END IF;
      amount := CASE OLD.event_type WHEN 'charge.refunded' THEN object->'amount_refunded'
        WHEN 'payment_intent.succeeded' THEN object->'amount_received' ELSE object->'amount' END;
      NEW.provider_object_id := COALESCE(NEW.provider_object_id, NULLIF(object->>'id', ''));
      NEW.provider_livemode := COALESCE(NEW.provider_livemode,
        CASE WHEN OLD.payload ? 'livemode' THEN OLD.payload->'livemode' = 'true'::jsonb END);
      NEW.provider_account_id := COALESCE(NEW.provider_account_id, NULLIF(OLD.payload->>'account', ''));
      NEW.provider_amount_cents := COALESCE(NEW.provider_amount_cents,
        CASE WHEN jsonb_typeof(amount) = 'number' AND (amount #>> '{}') ~ '^[0-9]+$' THEN (amount #>> '{}')::bigint END);
      NEW.provider_currency := COALESCE(NEW.provider_currency, lower(NULLIF(object->>'currency', '')));
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS webhook_events_keep_identity ON webhook_events;
    CREATE TRIGGER webhook_events_keep_identity BEFORE UPDATE OF payload ON webhook_events
      FOR EACH ROW WHEN (OLD.payload IS DISTINCT FROM NEW.payload
        AND OLD.event_type IN ('payment_intent.succeeded', 'refund.created', 'refund.updated', 'refund.failed', 'charge.refund.updated', 'charge.refunded', 'charge.dispute.created', 'charge.dispute.updated', 'charge.dispute.closed'))
      EXECUTE FUNCTION hafapass_keep_receipt_identity();
    CREATE OR REPLACE FUNCTION hafapass_unclassified_capture(target bigint) RETURNS boolean
    LANGUAGE sql STABLE AS $$
      SELECT COALESCE((
        SELECT p.provider = 'stripe' AND p.status IN (1, 4, 5) AND p.capture_recorded_at IS NOT NULL
          AND p.provider_environment IN ('test', 'live') AND p.provider_payment_id IS NOT NULL
          AND NOT starts_with(p.provider_payment_id, 'sim_') AND p.provider_payload->>'simulated' IS DISTINCT FROM 'true'
          AND CASE
            -- Another payment's order-scope capture marked the order. Every
            -- further capture on it is another order-scope capture
            -- (OrderLifecycle), whatever the order's status since; there is
            -- no sale for a test capture to compete with.
            WHEN o.never_fulfilled_at IS NOT NULL THEN true
            -- Payment.live_or_legacy_capture's mode rule: a test capture never
            -- competes with a live one for the same sale.
            WHEN o.fulfilled_by_payment_id IS NOT NULL THEN o.fulfilled_by_payment_id <> p.id
              AND EXISTS (SELECT 1 FROM payments f WHERE f.id = o.fulfilled_by_payment_id
                AND hafapass_live_or_legacy(f.provider_environment, f.provider_payload)
                  = hafapass_live_or_legacy(p.provider_environment, p.provider_payload))
            ELSE (o.completed_at IS NOT NULL OR o.status IN (1, 2, 4))
              AND EXISTS (SELECT 1 FROM payments other WHERE other.order_id = o.id AND other.id <> p.id
                AND other.status IN (1, 4, 5)
                AND hafapass_live_or_legacy(other.provider_environment, other.provider_payload)
                  = hafapass_live_or_legacy(p.provider_environment, p.provider_payload))
              -- With no recorded fulfilling payment, the order's first capture
              -- of this mode (a capture from before the cutover counts as
              -- first) may be the sale itself: once another capture of this
              -- mode has an item, that first capture alone is no longer an
              -- overlap. Every later capture stays one until it has its own
              -- item, so one payment's item never hides another's liability.
              AND NOT (EXISTS (SELECT 1 FROM reconciliation_exceptions held JOIN payments other ON other.id = held.payment_id
                  WHERE other.order_id = o.id AND other.id <> p.id AND held.code IN ('late_payment_success_after_inventory_release', 'late_payment_success_after_hold_expiry', 'pass_all_included_nights_cancelled', 'unfulfilled_second_capture', 'never_fulfilled_ownership_ambiguous', 'never_fulfilled_classification_quarantined', 'never_fulfilled_backfill_ambiguous', 'never_fulfilled_backfill_restatement')
                    AND hafapass_live_or_legacy(other.provider_environment, other.provider_payload)
                      = hafapass_live_or_legacy(p.provider_environment, p.provider_payload))
                AND NOT EXISTS (SELECT 1 FROM payments earlier WHERE earlier.order_id = o.id AND earlier.id <> p.id
                  AND earlier.status IN (1, 4, 5)
                  AND hafapass_live_or_legacy(earlier.provider_environment, earlier.provider_payload)
                    = hafapass_live_or_legacy(p.provider_environment, p.provider_payload)
                  AND (COALESCE(earlier.capture_recorded_at, '-infinity'::timestamp), earlier.id) < (p.capture_recorded_at, p.id)))
          END
          AND NOT EXISTS (SELECT 1 FROM never_fulfilled_captures c WHERE c.payment_id = p.id)
          AND NOT EXISTS (SELECT 1 FROM reconciliation_exceptions re WHERE re.payment_id = p.id
            AND re.code IN ('late_payment_success_after_inventory_release', 'late_payment_success_after_hold_expiry', 'pass_all_included_nights_cancelled', 'unfulfilled_second_capture', 'never_fulfilled_ownership_ambiguous', 'never_fulfilled_classification_quarantined', 'never_fulfilled_backfill_ambiguous', 'never_fulfilled_backfill_restatement'))
        FROM payments p JOIN orders o ON o.id = p.order_id WHERE p.id = target), false)
    $$;

    -- When an unclassified overlap capture began to overlap, or NULL when the
    -- payment is not one: the later of its own capture and the order's first
    -- other capture that can compete with it, by the predicate's own mode
    -- rule (of its mode; any mode on a marked order). The fulfilling or
    -- marking payment is one of them. A capture from before the cutover has
    -- no recording time and was captured before every recorded one, so it
    -- counts as the earliest (-infinity), never as absent. Recording times
    -- are database-stamped once (payments_capture_recorded_at), so a later
    -- capture only adds a competitor and can only make this earlier.
    CREATE OR REPLACE FUNCTION hafapass_overlap_hold_start(target bigint) RETURNS timestamp
    LANGUAGE sql STABLE AS $$
      SELECT GREATEST(p.capture_recorded_at, (SELECT MIN(COALESCE(other.capture_recorded_at, '-infinity'::timestamp))
          FROM payments other WHERE other.order_id = p.order_id AND other.id <> p.id
            AND other.status IN (1, 4, 5)
            AND (o.never_fulfilled_at IS NOT NULL OR hafapass_live_or_legacy(other.provider_environment, other.provider_payload)
              = hafapass_live_or_legacy(p.provider_environment, p.provider_payload))))
        FROM payments p JOIN orders o ON o.id = p.order_id WHERE p.id = target AND hafapass_unclassified_capture(p.id)
    $$;

    CREATE OR REPLACE FUNCTION hafapass_payout_block_start(target_event bigint) RETURNS timestamp
    LANGUAGE sql STABLE AS $$
      SELECT MIN(started) FROM (
        SELECT LEAST(re.created_at, COALESCE(re.hold_started_at, re.created_at)) AS started
          FROM reconciliation_exceptions re
          WHERE re.status = 0 AND re.code IN ('late_payment_success_after_inventory_release', 'late_payment_success_after_hold_expiry', 'pass_all_included_nights_cancelled', 'unfulfilled_second_capture', 'never_fulfilled_ownership_ambiguous', 'never_fulfilled_classification_quarantined', 'never_fulfilled_return_quarantined', 'never_fulfilled_backfill_ambiguous', 'never_fulfilled_backfill_restatement', 'never_fulfilled_repayment_reopened', 'never_fulfilled_sale_effects_held')
            AND (re.order_id IN (SELECT id FROM orders WHERE event_id = target_event)
              OR re.payment_id IN (SELECT p.id FROM payments p JOIN orders o ON o.id = p.order_id
                WHERE o.event_id = target_event))
        UNION ALL
        SELECT hafapass_overlap_hold_start(p.id) FROM payments p JOIN orders o ON o.id = p.order_id
          WHERE o.event_id = target_event AND p.capture_recorded_at IS NOT NULL
            AND p.status IN (1, 4, 5)
      ) blocks
    $$;

    -- Stamped on insert by the database (whatever value a writer supplies)
    -- and never changed: the earliest overlap start of any unclassified
    -- capture on the payment's order (its own included), or the start of a
    -- blocking item still open on the same payment, whichever is earlier.
    -- The new row is not yet visible here, so the first classifying exception
    -- still sees the overlap it is about to end, and any start it takes out
    -- of the overlap set (its own, or the order's first capture that its
    -- item stops counting) is kept on the row. The items discovery writes
    -- after it (a quarantine, a repayment wait) keep the same start for as
    -- long as the payment's hold stays open. Once every item on the payment
    -- is closed and no capture on the order is unclassified, a later item
    -- starts at its own time.
    CREATE OR REPLACE FUNCTION hafapass_exception_hold_start() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'UPDATE' THEN
        IF NEW.hold_started_at IS DISTINCT FROM OLD.hold_started_at THEN
          RAISE EXCEPTION 'An exception''s hold start is recorded once, from its capture' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END IF;
      NEW.hold_started_at := CASE WHEN NEW.payment_id IS NOT NULL AND NEW.code IN ('late_payment_success_after_inventory_release', 'late_payment_success_after_hold_expiry', 'pass_all_included_nights_cancelled', 'unfulfilled_second_capture', 'never_fulfilled_ownership_ambiguous', 'never_fulfilled_classification_quarantined', 'never_fulfilled_return_quarantined', 'never_fulfilled_backfill_ambiguous', 'never_fulfilled_backfill_restatement', 'never_fulfilled_repayment_reopened', 'never_fulfilled_sale_effects_held')
        THEN LEAST((SELECT MIN(hafapass_overlap_hold_start(x.id)) FROM payments x
            WHERE x.order_id = (SELECT target.order_id FROM payments target WHERE target.id = NEW.payment_id)),
          (SELECT MIN(LEAST(re.created_at, COALESCE(re.hold_started_at, re.created_at))) FROM reconciliation_exceptions re
            WHERE re.payment_id = NEW.payment_id AND re.status = 0
              AND re.code IN ('late_payment_success_after_inventory_release', 'late_payment_success_after_hold_expiry', 'pass_all_included_nights_cancelled', 'unfulfilled_second_capture', 'never_fulfilled_ownership_ambiguous', 'never_fulfilled_classification_quarantined', 'never_fulfilled_return_quarantined', 'never_fulfilled_backfill_ambiguous', 'never_fulfilled_backfill_restatement', 'never_fulfilled_repayment_reopened', 'never_fulfilled_sale_effects_held'))) END;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS reconciliation_exceptions_hold_start ON reconciliation_exceptions;
    CREATE TRIGGER reconciliation_exceptions_hold_start BEFORE INSERT OR UPDATE OF hold_started_at ON reconciliation_exceptions
      FOR EACH ROW EXECUTE FUNCTION hafapass_exception_hold_start();

    -- The event row every capture holds until it commits (docs/LOCKING.md
    -- rank 2). Already held by this release's payout writers; NOWAIT for an
    -- older writer that holds the payout (rank 3) and would otherwise wait
    -- in reverse order. A row lock taken in this block's subtransaction is
    -- kept when the block returns.
    CREATE OR REPLACE FUNCTION hafapass_lock_payout_event(target_event bigint) RETURNS void
    LANGUAGE plpgsql AS $$
    BEGIN
      PERFORM 1 FROM events WHERE id = target_event FOR NO KEY UPDATE NOWAIT;
    EXCEPTION WHEN lock_not_available THEN
      RAISE EXCEPTION 'Repayment fence: event % has a sale or capture in progress; retry this payout step', target_event
        USING ERRCODE = '55P03';
    END;
    $$;

    -- 20261126140000's fence, after the event lock (finding 3).
    CREATE OR REPLACE FUNCTION hafapass_payout_repayment_fence() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      block_start timestamp;
      submitted_before boolean;
    BEGIN
      IF TG_OP = 'UPDATE' AND (NEW.status = OLD.status
          OR NEW.status NOT IN (0, 1, 2)) THEN
        RETURN NEW;
      END IF;
      -- Lock in one statement; every later statement reads a fresh snapshot.
      PERFORM hafapass_lock_payout_event(NEW.event_id);
      IF TG_OP = 'INSERT' AND hafapass_settlement_reader_required(NEW.event_id) THEN
        RAISE EXCEPTION 'Repayment fence: this event''s payouts need the never-fulfilled settlement reader'
          USING ERRCODE = '23514';
      END IF;
      IF NEW.status NOT IN (0, 1, 2) THEN
        RETURN NEW;
      END IF;
      block_start := hafapass_payout_block_start(NEW.event_id);
      IF block_start IS NULL THEN
        RETURN NEW;
      END IF;
      IF TG_OP = 'UPDATE' THEN
        submitted_before := EXISTS (SELECT 1 FROM audit_logs a
          WHERE a.auditable_type = 'Payout' AND a.auditable_id = NEW.id AND a.action = 'payout.submission_requested'
            AND a.occurred_at < block_start);
        IF NEW.status = 1 AND OLD.status = 0 AND submitted_before THEN
          RETURN NEW;
        END IF;
        IF NEW.status = 2
            AND OLD.status IN (0, 1, 5)
            AND submitted_before AND NEW.paid_at IS NOT NULL AND NEW.paid_at < block_start
            AND current_setting('hafapass.payout_transfer', true) IS NOT DISTINCT FROM NEW.id::text THEN
          RETURN NEW;
        END IF;
        IF NEW.status = 2 THEN
          RAISE EXCEPTION 'Repayment fence: payout % needs verified transfer evidence from before the hold', NEW.id
            USING ERRCODE = '23514';
        END IF;
      END IF;
      RAISE EXCEPTION 'Repayment fence: a buyer repayment on this event is unresolved' USING ERRCODE = '23514';
    END;
    $$;

    CREATE OR REPLACE FUNCTION hafapass_payout_submission_fence() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      target_event bigint;
    BEGIN
      SELECT event_id INTO target_event FROM payouts WHERE id = NEW.auditable_id;
      PERFORM hafapass_lock_payout_event(target_event);
      IF hafapass_payout_block_start(target_event) IS NOT NULL THEN
        RAISE EXCEPTION 'Repayment fence: a buyer repayment on this event is unresolved' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;

    CREATE OR REPLACE FUNCTION hafapass_settlement_finalization_fence() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      PERFORM hafapass_lock_payout_event(NEW.event_id);
      IF hafapass_payout_block_start(NEW.event_id) IS NOT NULL THEN
        RAISE EXCEPTION 'Repayment fence: a buyer repayment on this event is unresolved' USING ERRCODE = '23514';
      END IF;
      IF hafapass_settlement_reader_required(NEW.event_id) THEN
        RAISE EXCEPTION 'Repayment fence: this event''s statement needs the never-fulfilled settlement reader'
          USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;
    CREATE OR REPLACE FUNCTION hafapass_stamp_custody_determination() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.determined_at IS NOT NULL THEN
        RAISE EXCEPTION 'A custody determination''s time is stamped by the database' USING ERRCODE = '23514';
      END IF;
      NEW.determined_at := timezone('UTC', clock_timestamp());
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS payout_custody_determinations_stamp ON payout_custody_determinations;
    CREATE TRIGGER payout_custody_determinations_stamp BEFORE INSERT ON payout_custody_determinations
      FOR EACH ROW EXECUTE FUNCTION hafapass_stamp_custody_determination();
    DROP TRIGGER IF EXISTS payout_custody_determinations_append_only ON payout_custody_determinations;
    CREATE TRIGGER payout_custody_determinations_append_only BEFORE UPDATE OR DELETE ON payout_custody_determinations
      FOR EACH ROW EXECUTE FUNCTION hafapass_append_only();
    CREATE OR REPLACE TRIGGER payout_custody_determinations_no_truncate BEFORE TRUNCATE ON payout_custody_determinations
      FOR EACH STATEMENT EXECUTE FUNCTION hafapass_append_only_truncate();
    CREATE OR REPLACE FUNCTION hafapass_overpaid_platform_only(target bigint) RETURNS boolean
    LANGUAGE sql STABLE AS $$
      SELECT COALESCE((
        SELECT
          NOT EXISTS (SELECT 1 FROM refunds r WHERE r.payment_id = target AND r.status = 1
            AND NOT EXISTS (SELECT 1 FROM buyer_return_postings p WHERE p.kind = 'refund' AND p.source_type = 'Refund'
              AND p.source_id = r.id))
          AND NOT EXISTS (SELECT 1 FROM disputes d WHERE d.payment_id = target AND d.status = 2
            AND d.amount_cents > 0 AND NOT EXISTS (SELECT 1 FROM buyer_return_postings p WHERE p.kind = 'dispute_loss'
              AND p.source_type = 'Dispute' AND p.source_id = d.id))
          AND NOT EXISTS (SELECT 1 FROM disputes d WHERE d.payment_id = target AND d.status = 2
            AND d.loss_reversed_at IS NOT NULL AND NOT EXISTS (SELECT 1 FROM buyer_return_postings p
              WHERE p.kind = 'dispute_loss_reversal' AND p.source_type = 'Dispute' AND p.source_id = d.id))
          AND NOT EXISTS (SELECT 1 FROM buyer_return_postings p WHERE p.never_fulfilled_capture_id = c.id
            AND p.recognition_state <> 'recognized')
          AND NOT EXISTS (SELECT 1 FROM refunds r WHERE r.payment_id = target AND r.status = 0)
          AND NOT EXISTS (SELECT 1 FROM disputes d WHERE d.payment_id = target AND d.status = 0)
          AND NOT EXISTS (SELECT 1 FROM repayment_operations o WHERE o.never_fulfilled_capture_id = c.id
            AND o.state NOT IN ('succeeded', 'failed_terminal'))
          AND NOT EXISTS (SELECT 1 FROM reconciliation_exceptions re WHERE re.payment_id = target
            AND re.status = 0 AND re.code IN ('late_payment_success_after_inventory_release', 'late_payment_success_after_hold_expiry', 'pass_all_included_nights_cancelled', 'unfulfilled_second_capture', 'never_fulfilled_ownership_ambiguous', 'never_fulfilled_classification_quarantined', 'never_fulfilled_return_quarantined', 'never_fulfilled_backfill_ambiguous', 'never_fulfilled_backfill_restatement', 'never_fulfilled_repayment_reopened', 'never_fulfilled_sale_effects_held'))
          AND NOT EXISTS (SELECT 1 FROM balance_adjustments a WHERE (c.capture_scope = 'order' AND a.order_id = c.order_id)
            OR a.dispute_id IN (SELECT d.id FROM disputes d WHERE d.payment_id = target
              OR (c.capture_scope = 'order' AND d.order_id = c.order_id)))
          AND NOT EXISTS (SELECT 1 FROM payout_custody_determinations pcd WHERE target = ANY (pcd.qualifying_payment_ids))
        FROM never_fulfilled_captures c WHERE c.payment_id = target), false)
    $$;

    -- When the P4 proof stopped holding (review finding 2, 17324039): the
    -- earliest durable recording time of a fact that now defeats
    -- hafapass_overpaid_platform_only, one branch per condition there. Every
    -- time is an immutable row time (database-stamped where A1 stamps one),
    -- so repeated reads, the reconciler and the fences all see one cutoff; it
    -- never advances with the reading transaction. NULL when no such fact is
    -- found (the payout block start then falls back to the exception's own
    -- opening, the earliest possible hold). A proof that failed, recovered
    -- and failed again starts at the facts that defeat it now.
    CREATE OR REPLACE FUNCTION hafapass_overpaid_proof_lost_at(target bigint) RETURNS timestamp
    LANGUAGE sql STABLE AS $$
      SELECT MIN(lost) FROM never_fulfilled_captures c, LATERAL (
        SELECT r.created_at AS lost FROM refunds r WHERE r.payment_id = target AND r.status = 1
          AND NOT EXISTS (SELECT 1 FROM buyer_return_postings p WHERE p.kind = 'refund' AND p.source_type = 'Refund'
            AND p.source_id = r.id)
        UNION ALL
        SELECT d.created_at FROM disputes d WHERE d.payment_id = target AND d.status = 2
          AND d.amount_cents > 0 AND NOT EXISTS (SELECT 1 FROM buyer_return_postings p WHERE p.kind = 'dispute_loss'
            AND p.source_type = 'Dispute' AND p.source_id = d.id)
        UNION ALL
        SELECT d.loss_reversed_at FROM disputes d WHERE d.payment_id = target AND d.status = 2
          AND d.loss_reversed_at IS NOT NULL AND NOT EXISTS (SELECT 1 FROM buyer_return_postings p
            WHERE p.kind = 'dispute_loss_reversal' AND p.source_type = 'Dispute' AND p.source_id = d.id)
        UNION ALL
        SELECT p.recorded_at FROM buyer_return_postings p WHERE p.never_fulfilled_capture_id = c.id
          AND p.recognition_state <> 'recognized'
        UNION ALL
        SELECT r.created_at FROM refunds r WHERE r.payment_id = target AND r.status = 0
        UNION ALL
        SELECT d.created_at FROM disputes d WHERE d.payment_id = target AND d.status = 0
        UNION ALL
        SELECT o.created_at FROM repayment_operations o WHERE o.never_fulfilled_capture_id = c.id
          AND o.state NOT IN ('succeeded', 'failed_terminal')
        UNION ALL
        SELECT LEAST(re.created_at, COALESCE(re.hold_started_at, re.created_at)) FROM reconciliation_exceptions re
          WHERE re.payment_id = target AND re.status = 0
            AND re.code IN ('late_payment_success_after_inventory_release', 'late_payment_success_after_hold_expiry', 'pass_all_included_nights_cancelled', 'unfulfilled_second_capture', 'never_fulfilled_ownership_ambiguous', 'never_fulfilled_classification_quarantined', 'never_fulfilled_return_quarantined', 'never_fulfilled_backfill_ambiguous', 'never_fulfilled_backfill_restatement', 'never_fulfilled_repayment_reopened', 'never_fulfilled_sale_effects_held')
        UNION ALL
        SELECT a.created_at FROM balance_adjustments a WHERE (c.capture_scope = 'order' AND a.order_id = c.order_id)
          OR a.dispute_id IN (SELECT d.id FROM disputes d WHERE d.payment_id = target
            OR (c.capture_scope = 'order' AND d.order_id = c.order_id))
        UNION ALL
        SELECT pcd.determined_at FROM payout_custody_determinations pcd WHERE target = ANY (pcd.qualifying_payment_ids)
      ) facts
      WHERE c.payment_id = target
    $$;

    CREATE OR REPLACE FUNCTION hafapass_payout_block_start(target_event bigint) RETURNS timestamp
    LANGUAGE sql STABLE AS $$
      SELECT MIN(started) FROM (
        SELECT LEAST(re.created_at, COALESCE(re.hold_started_at, re.created_at)) AS started
          FROM reconciliation_exceptions re
          WHERE re.status = 0 AND re.code IN ('late_payment_success_after_inventory_release', 'late_payment_success_after_hold_expiry', 'pass_all_included_nights_cancelled', 'unfulfilled_second_capture', 'never_fulfilled_ownership_ambiguous', 'never_fulfilled_classification_quarantined', 'never_fulfilled_return_quarantined', 'never_fulfilled_backfill_ambiguous', 'never_fulfilled_backfill_restatement', 'never_fulfilled_repayment_reopened', 'never_fulfilled_sale_effects_held')
            AND (re.order_id IN (SELECT id FROM orders WHERE event_id = target_event)
              OR re.payment_id IN (SELECT p.id FROM payments p JOIN orders o ON o.id = p.order_id
                WHERE o.event_id = target_event))
        UNION ALL
        SELECT hafapass_overlap_hold_start(p.id) FROM payments p JOIN orders o ON o.id = p.order_id
          WHERE o.event_id = target_event AND p.capture_recorded_at IS NOT NULL
            AND p.status IN (1, 4, 5)
        UNION ALL
        SELECT GREATEST(re.created_at, hafapass_overpaid_proof_lost_at(re.payment_id)) FROM reconciliation_exceptions re
          WHERE re.status = 0 AND re.code = 'never_fulfilled_buyer_overpaid'
            AND (re.order_id IN (SELECT id FROM orders WHERE event_id = target_event)
              OR re.payment_id IN (SELECT p.id FROM payments p JOIN orders o ON o.id = p.order_id
                WHERE o.event_id = target_event))
            AND NOT hafapass_overpaid_platform_only(re.payment_id)
      ) blocks
    $$;

    CREATE OR REPLACE FUNCTION hafapass_stamp_fee_facts_recorded_at() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'INSERT' THEN
        IF NEW.facts_recorded_at IS NOT NULL THEN
          RAISE EXCEPTION 'A fee fact''s recording time is stamped by the database' USING ERRCODE = '23514';
        END IF;
        IF NEW.evidence_digest IS NOT NULL THEN
          NEW.facts_recorded_at := timezone('UTC', clock_timestamp());
        END IF;
        RETURN NEW;
      END IF;
      IF OLD.facts_recorded_at IS NOT NULL THEN
        IF NEW.facts_recorded_at IS DISTINCT FROM OLD.facts_recorded_at THEN
          RAISE EXCEPTION 'A fee fact''s recording time is set once' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END IF;
      IF NEW.evidence_digest IS NOT NULL AND (OLD.evidence_digest IS NULL
          OR current_setting('hafapass.fee_facts_backfill', true) IS NOT DISTINCT FROM NEW.id::text) THEN
        NEW.facts_recorded_at := timezone('UTC', clock_timestamp());
      ELSIF NEW.facts_recorded_at IS NOT NULL THEN
        RAISE EXCEPTION 'A fee fact''s recording time is stamped by the database' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS stripe_fee_evidences_facts_recorded_at ON stripe_fee_evidences;
    CREATE TRIGGER stripe_fee_evidences_facts_recorded_at BEFORE INSERT OR UPDATE ON stripe_fee_evidences
      FOR EACH ROW EXECUTE FUNCTION hafapass_stamp_fee_facts_recorded_at();
    CREATE OR REPLACE FUNCTION hafapass_event_has_classified_capture(target_event bigint) RETURNS boolean
    LANGUAGE sql STABLE AS $$
      SELECT EXISTS (SELECT 1 FROM never_fulfilled_captures c JOIN orders o ON o.id = c.order_id
        WHERE o.event_id = target_event)
    $$;

    CREATE OR REPLACE FUNCTION hafapass_settlement_reader_required(target_event bigint) RETURNS boolean
    LANGUAGE sql STABLE AS $$
      SELECT hafapass_event_has_classified_capture(target_event)
        AND current_setting('hafapass.settlement_reader', true) IS DISTINCT FROM 'nfc-a2'
    $$;

    CREATE OR REPLACE FUNCTION hafapass_settlement_restated_at(target_settlement bigint) RETURNS timestamp
    LANGUAGE sql STABLE AS $$
      SELECT CASE WHEN MIN(c.capture_recorded_at) IS NULL THEN NULL
        ELSE GREATEST(MIN(c.capture_recorded_at),
          (SELECT fc.recorded_at FROM financial_cutovers fc WHERE fc.key = 'a2_payout_entry')) END
      FROM settlements s
      JOIN orders o ON o.event_id = s.event_id
      JOIN never_fulfilled_captures c ON c.order_id = o.id
      WHERE s.id = target_settlement
        AND NOT EXISTS (SELECT 1 FROM settlement_items si WHERE si.settlement_id = s.id AND si.kind = 'adjustment'
          AND si.metadata->>'adjustment_kind' = 'never_fulfilled_capture'
          AND si.metadata->'payment_ids' @> jsonb_build_array(c.payment_id))
    $$;

    -- P4 proof, final form (CodeRabbit 4703321667, 4703321674, 4703321681).
    -- Every fact that can defeat the platform-only proof for one classified
    -- payment, whatever its state now, with the immutable time it began and
    -- whether it defeats the proof now. The A2 operational form
    -- (20261126170000) also required that no custody determination named
    -- the payment, which is always true for a classified one (custody never
    -- qualifies it); proof now also needs positive funding lineage: every
    -- payout on the event that moved or may move money (pending, processing,
    -- paid, held) was approved on a statement version that accounts for the
    -- payment with its $0 line. A version without that line may have funded
    -- the organizer from it, so the over-return then holds.
    -- CodeRabbit 4704013209: a reversed payout left money with the
    -- organizer until the bank's return is shown. Its reversal counts as
    -- recovered funds only when PayoutReconciler recorded the exact verified
    -- return (the bank's return reference, the full amount that left, and
    -- when it came back) in its durable proof, payout_return_proofs, with
    -- the reversal or attached to it later. A reversal recorded without it,
    -- by any release or raw SQL, still defeats the P4 proof.
    -- The amount that actually left for a payout: its disbursement plus any
    -- audited check amount adjustment (Payout#confirmed_check_amount_cents;
    -- a transfer has none, so it is the disbursement). CodeRabbit 4704932964.
    CREATE OR REPLACE FUNCTION hafapass_payout_amount_left(target_payout bigint) RETURNS bigint
    LANGUAGE sql STABLE AS $$
      SELECT po.amount_cents - po.withheld_cents - po.carried_withholding_cents
          + COALESCE((SELECT SUM(adj.amount_cents) FROM payout_check_adjustments adj WHERE adj.payout_id = po.id), 0)
        FROM payouts po WHERE po.id = target_payout
    $$;

    -- CodeRabbit 4704933005: the durable, non-personal proof of an exact
    -- verified return (payout_return_proofs), so the P4 proof and the
    -- reversal fence never read audit payloads that retention anonymizes.
    -- One row per payout, append-only, written only by this release's
    -- reconciler (hafapass.payout_return names the payout) with the amount
    -- that left, the return time (not before the transfer left, not after
    -- the database clock) and a SHA-256 digest of the bank's return
    -- reference (the reference text stays only in the audit). A row for the
    -- reversal itself commits only with its payout reversed; a row attached
    -- to a reversal already recorded (kind attached_return) needs the payout
    -- reversed when it is written and changes nothing on the payout.
    CREATE OR REPLACE FUNCTION hafapass_check_payout_return_proof() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      payout_status integer;
    BEGIN
      NEW.recorded_at := timezone('UTC', clock_timestamp());
      IF current_setting('hafapass.payout_return', true) IS DISTINCT FROM NEW.payout_id::text THEN
        RAISE EXCEPTION 'Payout return proof: record the return from the current release''s reconciler' USING ERRCODE = '23514';
      END IF;
      SELECT status INTO payout_status FROM payouts WHERE id = NEW.payout_id FOR NO KEY UPDATE;
      IF NEW.returned_amount_cents IS DISTINCT FROM hafapass_payout_amount_left(NEW.payout_id) THEN
        RAISE EXCEPTION 'Payout return proof: the returned amount must be the full amount that left' USING ERRCODE = '23514';
      END IF;
      IF NEW.return_reference_digest !~ '^[0-9a-f]{64}$' OR NEW.returned_at IS NULL OR NEW.sent_at IS NULL
          OR NEW.returned_at < NEW.sent_at OR NEW.returned_at > NEW.recorded_at THEN
        RAISE EXCEPTION 'Payout return proof: an exact return needs its reference and a return time after the transfer left'
          USING ERRCODE = '23514';
      END IF;
      IF NEW.kind = 'attached_return' AND payout_status IS DISTINCT FROM 4 THEN
        RAISE EXCEPTION 'Payout return proof: evidence is attached only to a reversal already recorded' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS payout_return_proofs_check ON payout_return_proofs;
    CREATE TRIGGER payout_return_proofs_check BEFORE INSERT ON payout_return_proofs
      FOR EACH ROW EXECUTE FUNCTION hafapass_check_payout_return_proof();
    DROP TRIGGER IF EXISTS payout_return_proofs_append_only ON payout_return_proofs;
    CREATE TRIGGER payout_return_proofs_append_only BEFORE UPDATE OR DELETE ON payout_return_proofs
      FOR EACH ROW EXECUTE FUNCTION hafapass_append_only();
    DROP TRIGGER IF EXISTS payout_return_proofs_append_only_truncate ON payout_return_proofs;
    CREATE TRIGGER payout_return_proofs_append_only_truncate BEFORE TRUNCATE ON payout_return_proofs
      FOR EACH STATEMENT EXECUTE FUNCTION hafapass_append_only_truncate();

    CREATE OR REPLACE FUNCTION hafapass_check_payout_return_proof_commit() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM payouts p WHERE p.id = NEW.payout_id AND p.status = 4) THEN
        RAISE EXCEPTION 'Payout return proof: a return commits only with its payout reversed' USING ERRCODE = '23514';
      END IF;
      RETURN NULL;
    END;
    $$;
    DROP TRIGGER IF EXISTS payout_return_proofs_commit ON payout_return_proofs;
    CREATE CONSTRAINT TRIGGER payout_return_proofs_commit AFTER INSERT ON payout_return_proofs
      DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION hafapass_check_payout_return_proof_commit();

    -- A2 recheck finding 1 (7664e143): the return is verified only when it
    -- is exact. CodeRabbit 4704933005: read from the durable proof, never
    -- from audit payloads; CodeRabbit 4704932964: the amount that left.
    CREATE OR REPLACE FUNCTION hafapass_payout_return_verified(target_payout bigint) RETURNS boolean
    LANGUAGE sql STABLE AS $$
      SELECT EXISTS (SELECT 1 FROM payout_return_proofs r WHERE r.payout_id = target_payout
        AND r.returned_amount_cents = hafapass_payout_amount_left(target_payout))
    $$;

    -- CodeRabbit 4704933000: a payout's settlement version is fixed once a
    -- custody determination names it (the determination is checked against
    -- the payout's own version only when it is inserted). Same-value writes
    -- and payouts without a determination are unaffected.
    -- CodeRabbit 4705527070: the version change and a determination's insert
    -- (hafapass_check_custody_determination) serialize on the payout row,
    -- FOR NO KEY UPDATE in both, before either compares. The update already
    -- holds the row (a BEFORE row trigger runs after its tuple lock; the
    -- PERFORM states it and is immediate). An insert that started first holds
    -- the row until it commits, so the update waits for it and then reads the
    -- determination in a fresh snapshot (each statement of this VOLATILE
    -- function takes a new one); an update that started first makes the
    -- insert wait and then read the new version. Only the payout row (rank
    -- 3) is taken, after any organization or event lock its writer holds,
    -- so neither waits in reverse order.
    CREATE OR REPLACE FUNCTION hafapass_guard_payout_settlement() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      PERFORM 1 FROM payouts WHERE id = OLD.id FOR NO KEY UPDATE;
      IF NEW.settlement_id IS DISTINCT FROM OLD.settlement_id
          AND EXISTS (SELECT 1 FROM payout_custody_determinations d WHERE d.payout_id = OLD.id) THEN
        RAISE EXCEPTION 'A payout''s settlement version is fixed once its custody is determined' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS payouts_settlement_guard ON payouts;
    CREATE TRIGGER payouts_settlement_guard BEFORE UPDATE OF settlement_id ON payouts
      FOR EACH ROW EXECUTE FUNCTION hafapass_guard_payout_settlement();

    -- A2 recheck finding 1 (7664e143): the reversal boundary for every
    -- writer, A1 during the overlap or after a code rollback included. On an
    -- event with a never-fulfilled capture a payout becomes reversed (its
    -- amount released to be paid again) only when its transaction also
    -- records the exact verified return above, and, for a transfer the
    -- provider accepted after a fence refused it, only after finance recorded
    -- that acceptance (so CPA books the outgoing transfer and its return,
    -- each once; finding 2). Checked when the transaction commits, so the
    -- proof the same transaction writes after the status change counts. It
    -- first takes the event row the way the other payout fences do (already
    -- held by both releases' reconcilers, NOWAIT for any other writer, so it
    -- never waits in reverse order behind a capture); a capture that
    -- committed first is then visible, and one that has not yet started
    -- waits for this commit and is fenced by the P4 proof (the reversed
    -- payout's version lacks its $0 line). Ordinary events are unaffected.
    -- A2 recheck finding 1 (758485ae): a transfer the provider accepted
    -- (payouts.provider_accepted_at, hafapass_guard_accepted_transfer), on
    -- any event, is reversed only after finance recorded the acceptance and
    -- with the durable proof of its exact return: the accepted-transfer
    -- kind, the full amount that left, sent at its marker (or, for an
    -- observed marker, at the bank's earlier transfer time, see below).
    CREATE OR REPLACE FUNCTION hafapass_check_payout_reversal() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      accepted_at timestamp;
      accepted_basis text;
      acceptance_recorded_at timestamp;
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM payouts p WHERE p.id = NEW.id AND p.status = 4) THEN
        RETURN NULL;
      END IF;
      PERFORM hafapass_lock_payout_event(NEW.event_id);
      SELECT p.provider_accepted_at, p.provider_accepted_basis, p.accepted_transfer_recorded_at
        INTO accepted_at, accepted_basis, acceptance_recorded_at
        FROM payouts p WHERE p.id = NEW.id;
      IF accepted_at IS NOT NULL THEN
        IF acceptance_recorded_at IS NULL THEN
          RAISE EXCEPTION 'Payout reversal fence: payout % is a transfer the provider accepted; record the accepted transfer before its return', NEW.id
            USING ERRCODE = '23514';
        END IF;
        -- Sent at the marker, or (CodeRabbit 4706251665) for a marker this
        -- release only observed, at the bank's transfer time finance showed:
        -- before the observation and not before the submission request.
        IF NOT EXISTS (SELECT 1 FROM payout_return_proofs r WHERE r.payout_id = NEW.id AND r.kind = 'accepted_transfer_return'
            AND r.returned_amount_cents = hafapass_payout_amount_left(NEW.id)
            AND (r.sent_at = accepted_at OR (accepted_basis = 'locally_observed' AND r.sent_at < accepted_at
              AND r.sent_at >= (SELECT MIN(a.occurred_at) FROM audit_logs a WHERE a.auditable_type = 'Payout'
                AND a.auditable_id = NEW.id AND a.action = 'payout.submission_requested')))) THEN
          RAISE EXCEPTION 'Payout reversal fence: payout % is a transfer the provider accepted; record its return from the current release with the bank''s exact return evidence', NEW.id
            USING ERRCODE = '23514';
        END IF;
        RETURN NULL;
      END IF;
      -- CodeRabbit 4706251688: an acceptance shown only by its conflict audit
      -- (no marker; no release writes one, and the A2 preflight counts them)
      -- has no time to compare a return with. On any event it is never
      -- reversed; finance escalates it for an approved disposition, as the
      -- current reconciler requires.
      IF EXISTS (SELECT 1 FROM audit_logs a WHERE a.auditable_type = 'Payout' AND a.auditable_id = NEW.id
            AND a.action = 'payout.provider_result_conflict' AND a.metadata->>'conflict_reason' = 'provider_paid_refused_by_fence') THEN
        RAISE EXCEPTION 'Payout reversal fence: payout % has a provider acceptance recorded only in its audit trail; escalate it for an approved disposition', NEW.id
          USING ERRCODE = '23514';
      END IF;
      IF NOT hafapass_event_has_classified_capture(NEW.event_id) THEN
        RETURN NULL;
      END IF;
      IF NOT hafapass_payout_return_verified(NEW.id) THEN
        RAISE EXCEPTION 'Payout reversal fence: payout % is on an event with a never-fulfilled capture; record its reversal from the current release with the bank''s exact return evidence', NEW.id
          USING ERRCODE = '23514';
      END IF;
      RETURN NULL;
    END;
    $$;
    DROP TRIGGER IF EXISTS payouts_reversal_return_check ON payouts;
    CREATE CONSTRAINT TRIGGER payouts_reversal_return_check AFTER UPDATE OF status ON payouts
      DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
      WHEN (NEW.status = 4 AND OLD.status IS DISTINCT FROM 4)
      EXECUTE FUNCTION hafapass_check_payout_reversal();
    DROP TRIGGER IF EXISTS payouts_reversal_return_check_on_insert ON payouts;
    CREATE CONSTRAINT TRIGGER payouts_reversal_return_check_on_insert AFTER INSERT ON payouts
      DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.status = 4)
      EXECUTE FUNCTION hafapass_check_payout_reversal();

    CREATE OR REPLACE FUNCTION hafapass_overpaid_proof_facts(target bigint)
      RETURNS TABLE (started timestamp, defeating boolean)
    LANGUAGE sql STABLE AS $$
      SELECT f.started, f.defeating FROM never_fulfilled_captures c JOIN orders o ON o.id = c.order_id, LATERAL (
        SELECT r.created_at, (r.status = 0 OR (r.status = 1
            AND NOT EXISTS (SELECT 1 FROM buyer_return_postings p WHERE p.kind = 'refund' AND p.source_type = 'Refund'
              AND p.source_id = r.id)))
          FROM refunds r WHERE r.payment_id = target
        UNION ALL
        SELECT d.created_at, (d.status = 0 OR (d.status = 2 AND d.amount_cents > 0
            AND NOT EXISTS (SELECT 1 FROM buyer_return_postings p WHERE p.kind = 'dispute_loss'
              AND p.source_type = 'Dispute' AND p.source_id = d.id)))
          FROM disputes d WHERE d.payment_id = target
        UNION ALL
        SELECT d.loss_reversed_at, (d.status = 2 AND NOT EXISTS (SELECT 1 FROM buyer_return_postings p
            WHERE p.kind = 'dispute_loss_reversal' AND p.source_type = 'Dispute' AND p.source_id = d.id))
          FROM disputes d WHERE d.payment_id = target AND d.loss_reversed_at IS NOT NULL
        UNION ALL
        SELECT p.recorded_at, true FROM buyer_return_postings p WHERE p.never_fulfilled_capture_id = c.id
          AND p.recognition_state <> 'recognized'
        UNION ALL
        SELECT op.created_at, op.state NOT IN ('succeeded', 'failed_terminal') FROM repayment_operations op
          WHERE op.never_fulfilled_capture_id = c.id
        UNION ALL
        SELECT LEAST(re.created_at, COALESCE(re.hold_started_at, re.created_at)), re.status = 0
          FROM reconciliation_exceptions re WHERE re.payment_id = target AND re.code IN ('late_payment_success_after_inventory_release', 'late_payment_success_after_hold_expiry', 'pass_all_included_nights_cancelled', 'unfulfilled_second_capture', 'never_fulfilled_ownership_ambiguous', 'never_fulfilled_classification_quarantined', 'never_fulfilled_return_quarantined', 'never_fulfilled_backfill_ambiguous', 'never_fulfilled_backfill_restatement', 'never_fulfilled_repayment_reopened', 'never_fulfilled_sale_effects_held')
        UNION ALL
        SELECT a.created_at, true FROM balance_adjustments a WHERE (c.capture_scope = 'order' AND a.order_id = c.order_id)
          OR a.dispute_id IN (SELECT d.id FROM disputes d WHERE d.payment_id = target
            OR (c.capture_scope = 'order' AND d.order_id = c.order_id))
        UNION ALL
        SELECT pcd.determined_at, true FROM payout_custody_determinations pcd WHERE target = ANY (pcd.qualifying_payment_ids)
        UNION ALL
        SELECT po.created_at,
            po.status IN (0, 1, 2, 5)
              OR (po.status = 4 AND NOT hafapass_payout_return_verified(po.id))
          FROM payouts po WHERE po.event_id = o.event_id
            AND NOT EXISTS (SELECT 1 FROM settlement_items si WHERE si.settlement_id = po.settlement_id
              AND si.kind = 'adjustment' AND si.metadata->>'adjustment_kind' = 'never_fulfilled_capture'
              AND si.metadata->'payment_ids' @> jsonb_build_array(target))
      ) f (started, defeating)
      WHERE c.payment_id = target
    $$;

    CREATE OR REPLACE FUNCTION hafapass_overpaid_platform_only(target bigint) RETURNS boolean
    LANGUAGE sql STABLE AS $$
      SELECT EXISTS (SELECT 1 FROM never_fulfilled_captures c WHERE c.payment_id = target)
        AND NOT EXISTS (SELECT 1 FROM hafapass_overpaid_proof_facts(target) f WHERE f.defeating)
    $$;

    -- The latest moment the proof is known to have held on the payment's
    -- event: a payout submission authorized, or a statement version
    -- finalized, through this release's fences (both refuse while it fails;
    -- hafapass_payout_block_start). NULL when there is none.
    CREATE OR REPLACE FUNCTION hafapass_overpaid_proof_anchor(target bigint) RETURNS timestamp
    LANGUAGE sql STABLE AS $$
      SELECT GREATEST(
        (SELECT MAX(LEAST(a.occurred_at, a.created_at)) FROM audit_logs a JOIN payouts po ON po.id = a.auditable_id
          WHERE a.auditable_type = 'Payout' AND a.action = 'payout.submission_requested' AND po.event_id = o.event_id
            AND a.occurred_at >= (SELECT fc.recorded_at FROM financial_cutovers fc WHERE fc.key = 'a2_payout_entry')),
        (SELECT MAX(s.finalized_recorded_at) FROM settlements s WHERE s.event_id = o.event_id))
      FROM payments p JOIN orders o ON o.id = p.order_id WHERE p.id = target
    $$;

    -- When the proof stopped holding after `since`, the latest moment it is
    -- known to have held: the earliest start of any defeating fact recorded
    -- after `since`, in any state now, so a fact that resolves while another
    -- still defeats the proof never moves the cutoff later (a pending refund
    -- that becomes an unrecognized posting, for instance). A fact that began
    -- at or before `since` and defeats the proof now (one the check at
    -- `since` did not see) starts the hold at `since` itself.
    CREATE OR REPLACE FUNCTION hafapass_overpaid_proof_lost_at(target bigint, since timestamp) RETURNS timestamp
    LANGUAGE sql STABLE AS $$
      SELECT LEAST(
        (SELECT since WHERE since > '-infinity'::timestamp AND EXISTS (
          SELECT 1 FROM hafapass_overpaid_proof_facts(target) f WHERE f.defeating AND f.started <= since)),
        (SELECT MIN(f.started) FROM hafapass_overpaid_proof_facts(target) f WHERE f.started > since))
    $$;

    -- The same from the event's last passing fence (the payment's anchor).
    CREATE OR REPLACE FUNCTION hafapass_overpaid_proof_lost_at(target bigint) RETURNS timestamp
    LANGUAGE sql STABLE AS $$
      SELECT hafapass_overpaid_proof_lost_at(target, COALESCE(hafapass_overpaid_proof_anchor(target), '-infinity'::timestamp))
    $$;

    -- CodeRabbit 4704013214: when one open over-return exception's hold
    -- started, fixed for its whole unresolved episode. The database checks
    -- the proof when the exception is inserted (proof_checked_at, and
    -- hold_started_at when it failed then; hafapass_exception_hold_start),
    -- so the exception's own opening is a second durable point where the
    -- proof is known:
    --   failed at opening, and no fence has passed since: the hold started
    --     at the opening. No later fact, and no fact that resolves, moves it
    --     (a refund pending since before the last fence that posts while a
    --     newer one is pending, for instance).
    --   opened before this release checked it (proof_checked_at NULL), and
    --     no fence has passed since: unknown, so the opening (conservative).
    --   otherwise the proof was known to hold at the later of the last
    --     passing fence and the opening; the hold starts at the first
    --     defeating fact after that, in any state, or at that point for a
    --     fact before it that defeats the proof now.
    -- While the proof fails no fence passes (hafapass_payout_block_start), so
    -- the anchor stays put for the whole episode; once it recovers and a
    -- fence passes, a later episode starts from that fence. Never before the
    -- exception opened, and never the reading transaction's own time.
    CREATE OR REPLACE FUNCTION hafapass_overpaid_hold_start(target_exception bigint) RETURNS timestamp
    LANGUAGE sql STABLE AS $$
      SELECT CASE
        WHEN re.hold_started_at IS NOT NULL AND a.at < re.hold_started_at THEN LEAST(re.created_at, re.hold_started_at)
        WHEN re.proof_checked_at IS NULL AND a.at < re.created_at THEN re.created_at
        ELSE GREATEST(re.created_at, hafapass_overpaid_proof_lost_at(re.payment_id,
          GREATEST(a.at, COALESCE(re.proof_checked_at, '-infinity'::timestamp))))
      END
      FROM reconciliation_exceptions re,
        LATERAL (SELECT COALESCE(hafapass_overpaid_proof_anchor(re.payment_id), '-infinity'::timestamp) AS at) a
      WHERE re.id = target_exception
    $$;

    -- 20261126170000's block start, with each open over-return exception's
    -- hold from hafapass_overpaid_hold_start.
    CREATE OR REPLACE FUNCTION hafapass_payout_block_start(target_event bigint) RETURNS timestamp
    LANGUAGE sql STABLE AS $$
      SELECT MIN(started) FROM (
        SELECT LEAST(re.created_at, COALESCE(re.hold_started_at, re.created_at)) AS started
          FROM reconciliation_exceptions re
          WHERE re.status = 0 AND re.code IN ('late_payment_success_after_inventory_release', 'late_payment_success_after_hold_expiry', 'pass_all_included_nights_cancelled', 'unfulfilled_second_capture', 'never_fulfilled_ownership_ambiguous', 'never_fulfilled_classification_quarantined', 'never_fulfilled_return_quarantined', 'never_fulfilled_backfill_ambiguous', 'never_fulfilled_backfill_restatement', 'never_fulfilled_repayment_reopened', 'never_fulfilled_sale_effects_held')
            AND (re.order_id IN (SELECT id FROM orders WHERE event_id = target_event)
              OR re.payment_id IN (SELECT p.id FROM payments p JOIN orders o ON o.id = p.order_id
                WHERE o.event_id = target_event))
        UNION ALL
        SELECT hafapass_overlap_hold_start(p.id) FROM payments p JOIN orders o ON o.id = p.order_id
          WHERE o.event_id = target_event AND p.capture_recorded_at IS NOT NULL
            AND p.status IN (1, 4, 5)
        UNION ALL
        SELECT hafapass_overpaid_hold_start(re.id) FROM reconciliation_exceptions re
          WHERE re.status = 0 AND re.code = 'never_fulfilled_buyer_overpaid'
            AND (re.order_id IN (SELECT id FROM orders WHERE event_id = target_event)
              OR re.payment_id IN (SELECT p.id FROM payments p JOIN orders o ON o.id = p.order_id
                WHERE o.event_id = target_event))
            AND NOT hafapass_overpaid_platform_only(re.payment_id)
      ) blocks
    $$;

    -- 20261126150000's stamp, plus the over-return check at insert above:
    -- an over-return exception records when the database checked its proof
    -- (the earlier of its creation and the database clock) and, when the
    -- proof failed then, the same time as its hold start. Both are set once.
    -- The evaluator inserts it under the order lock its callers hold, which
    -- every refund and dispute writer also takes, so the check sees every
    -- return movement on the payment that committed first.
    CREATE OR REPLACE FUNCTION hafapass_exception_hold_start() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'UPDATE' THEN
        IF NEW.hold_started_at IS DISTINCT FROM OLD.hold_started_at
            OR NEW.proof_checked_at IS DISTINCT FROM OLD.proof_checked_at THEN
          RAISE EXCEPTION 'An exception''s hold start is recorded once, from its capture' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END IF;
      IF NEW.code = 'never_fulfilled_buyer_overpaid' AND NEW.payment_id IS NOT NULL THEN
        NEW.proof_checked_at := LEAST(COALESCE(NEW.created_at, 'infinity'::timestamp), timezone('UTC', clock_timestamp()));
        NEW.hold_started_at := CASE WHEN hafapass_overpaid_platform_only(NEW.payment_id) THEN NULL
          ELSE NEW.proof_checked_at END;
        RETURN NEW;
      END IF;
      NEW.proof_checked_at := NULL;
      NEW.hold_started_at := CASE WHEN NEW.payment_id IS NOT NULL AND NEW.code IN ('late_payment_success_after_inventory_release', 'late_payment_success_after_hold_expiry', 'pass_all_included_nights_cancelled', 'unfulfilled_second_capture', 'never_fulfilled_ownership_ambiguous', 'never_fulfilled_classification_quarantined', 'never_fulfilled_return_quarantined', 'never_fulfilled_backfill_ambiguous', 'never_fulfilled_backfill_restatement', 'never_fulfilled_repayment_reopened', 'never_fulfilled_sale_effects_held')
        THEN LEAST((SELECT MIN(hafapass_overlap_hold_start(x.id)) FROM payments x
            WHERE x.order_id = (SELECT target.order_id FROM payments target WHERE target.id = NEW.payment_id)),
          (SELECT MIN(LEAST(re.created_at, COALESCE(re.hold_started_at, re.created_at))) FROM reconciliation_exceptions re
            WHERE re.payment_id = NEW.payment_id AND re.status = 0
              AND re.code IN ('late_payment_success_after_inventory_release', 'late_payment_success_after_hold_expiry', 'pass_all_included_nights_cancelled', 'unfulfilled_second_capture', 'never_fulfilled_ownership_ambiguous', 'never_fulfilled_classification_quarantined', 'never_fulfilled_return_quarantined', 'never_fulfilled_backfill_ambiguous', 'never_fulfilled_backfill_restatement', 'never_fulfilled_repayment_reopened', 'never_fulfilled_sale_effects_held'))) END;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS reconciliation_exceptions_hold_start ON reconciliation_exceptions;
    CREATE TRIGGER reconciliation_exceptions_hold_start
      BEFORE INSERT OR UPDATE OF hold_started_at, proof_checked_at ON reconciliation_exceptions
      FOR EACH ROW EXECUTE FUNCTION hafapass_exception_hold_start();

    CREATE OR REPLACE FUNCTION hafapass_payout_repayment_fence() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      block_start timestamp;
      restated_at timestamp;
      cutoff timestamp;
      submitted_before boolean;
    BEGIN
      IF TG_OP = 'UPDATE' AND (NEW.status = OLD.status
          OR NEW.status NOT IN (0, 1, 2)) THEN
        RETURN NEW;
      END IF;
      -- Lock in one statement; every later statement reads a fresh snapshot.
      PERFORM hafapass_lock_payout_event(NEW.event_id);
      IF hafapass_settlement_reader_required(NEW.event_id) THEN
        RAISE EXCEPTION 'Payout entry fence: payouts on this event need the current settlement reader; retry from the current release'
          USING ERRCODE = '23514';
      END IF;
      -- CodeRabbit 4706251677: a pending payout moved to processing with the
      -- provider's acceptance marker records money that already left; it
      -- authorizes no transfer and frees nothing (the marker keeps it
      -- committed: hafapass_guard_accepted_transfer, which runs before this
      -- trigger, checked its identifier, conflict and basis). Refusing it
      -- after a hold or restatement cutoff that predates the submission
      -- would only roll the acceptance back, so it is never refused here.
      IF TG_OP = 'UPDATE' AND OLD.status = 0 AND NEW.status = 1
          AND OLD.provider_accepted_at IS NULL AND NEW.provider_accepted_at IS NOT NULL THEN
        RETURN NEW;
      END IF;
      IF NEW.status NOT IN (0, 1, 2) THEN
        RETURN NEW;
      END IF;
      block_start := hafapass_payout_block_start(NEW.event_id);
      restated_at := hafapass_settlement_restated_at(NEW.settlement_id);
      IF block_start IS NULL AND restated_at IS NULL THEN
        RETURN NEW;
      END IF;
      cutoff := LEAST(block_start, restated_at);
      IF TG_OP = 'UPDATE' THEN
        submitted_before := EXISTS (SELECT 1 FROM audit_logs a
          WHERE a.auditable_type = 'Payout' AND a.auditable_id = NEW.id AND a.action = 'payout.submission_requested'
            AND a.occurred_at < cutoff);
        IF NEW.status = 1 AND OLD.status = 0 AND submitted_before THEN
          RETURN NEW;
        END IF;
        IF NEW.status = 2
            AND OLD.status IN (0, 1, 5)
            AND submitted_before AND NEW.paid_at IS NOT NULL AND NEW.paid_at < cutoff
            AND current_setting('hafapass.payout_transfer', true) IS NOT DISTINCT FROM NEW.id::text THEN
          RETURN NEW;
        END IF;
        IF NEW.status = 2 AND block_start IS NOT NULL THEN
          RAISE EXCEPTION 'Repayment fence: payout % needs verified transfer evidence from before the hold', NEW.id
            USING ERRCODE = '23514';
        END IF;
        IF NEW.status = 2 THEN
          RAISE EXCEPTION 'Payout entry fence: payout % needs verified transfer evidence from before its statement was restated', NEW.id
            USING ERRCODE = '23514';
        END IF;
      END IF;
      IF block_start IS NOT NULL THEN
        RAISE EXCEPTION 'Repayment fence: a buyer repayment on this event is unresolved' USING ERRCODE = '23514';
      END IF;
      RAISE EXCEPTION 'Payout entry fence: this payout''s statement version predates a never-fulfilled capture; finalize the statement again'
        USING ERRCODE = '23514';
    END;
    $$;

    CREATE OR REPLACE FUNCTION hafapass_payout_submission_fence() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      target_event bigint;
      target_settlement bigint;
    BEGIN
      SELECT event_id, settlement_id INTO target_event, target_settlement FROM payouts WHERE id = NEW.auditable_id;
      PERFORM hafapass_lock_payout_event(target_event);
      IF hafapass_settlement_reader_required(target_event) THEN
        RAISE EXCEPTION 'Payout entry fence: payouts on this event need the current settlement reader; retry from the current release'
          USING ERRCODE = '23514';
      END IF;
      IF hafapass_payout_block_start(target_event) IS NOT NULL THEN
        RAISE EXCEPTION 'Repayment fence: a buyer repayment on this event is unresolved' USING ERRCODE = '23514';
      END IF;
      IF hafapass_settlement_restated_at(target_settlement) IS NOT NULL THEN
        RAISE EXCEPTION 'Payout entry fence: this payout''s statement version predates a never-fulfilled capture; finalize the statement again'
          USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;

    -- Unchanged body (20261126150000); it now calls the reader rule above.
    CREATE OR REPLACE FUNCTION hafapass_settlement_finalization_fence() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      PERFORM hafapass_lock_payout_event(NEW.event_id);
      IF hafapass_payout_block_start(NEW.event_id) IS NOT NULL THEN
        RAISE EXCEPTION 'Repayment fence: a buyer repayment on this event is unresolved' USING ERRCODE = '23514';
      END IF;
      IF hafapass_settlement_reader_required(NEW.event_id) THEN
        RAISE EXCEPTION 'Repayment fence: this event''s statement needs the never-fulfilled settlement reader'
          USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;

    CREATE OR REPLACE FUNCTION hafapass_stamp_settlement_finalization() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'UPDATE' AND OLD.status = 1 THEN
        IF NEW.finalized_reader IS DISTINCT FROM OLD.finalized_reader
            OR NEW.finalized_recorded_at IS DISTINCT FROM OLD.finalized_recorded_at
            OR NEW.reader_digest IS DISTINCT FROM OLD.reader_digest THEN
          RAISE EXCEPTION 'A finalized settlement''s reader, digest and recording time are set once' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END IF;
      IF NEW.status = 1 THEN
        NEW.finalized_reader := NULLIF(current_setting('hafapass.settlement_reader', true), '');
        NEW.finalized_recorded_at := timezone('UTC', clock_timestamp());
      ELSE
        NEW.finalized_reader := NULL;
        NEW.finalized_recorded_at := NULL;
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS settlements_finalization_stamp ON settlements;
    CREATE TRIGGER settlements_finalization_stamp BEFORE INSERT OR UPDATE ON settlements
      FOR EACH ROW EXECUTE FUNCTION hafapass_stamp_settlement_finalization();

    CREATE OR REPLACE FUNCTION hafapass_require_payout_custody() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM payout_custody_determinations d
          WHERE d.payout_id = NEW.id AND d.settlement_id = NEW.settlement_id) THEN
        RAISE EXCEPTION 'Payout custody fence: payout % has no custody determination; record it paid from the current release', NEW.id
          USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS payouts_require_custody ON payouts;
    CREATE TRIGGER payouts_require_custody BEFORE UPDATE OF status ON payouts
      FOR EACH ROW WHEN (NEW.status = 2 AND OLD.status IS DISTINCT FROM 2)
      EXECUTE FUNCTION hafapass_require_payout_custody();

    -- A payout inserted already paid (CodeRabbit 4703321688) has no earlier
    -- unpaid state in which this release writes its custody row, so it is
    -- checked when its transaction commits: it commits only with its
    -- determination for its own version, which for a paid payout is only
    -- the authorized historical derivation. Reversed is paid history too
    -- (CodeRabbit 4704013220): a payout inserted paid or reversed, or
    -- inserted paid and reversed before commit, needs the same row at
    -- commit; one written in the same transaction under the authorized
    -- derivation still passes. Payouts inserted before this migration are
    -- unaffected. The application never inserts paid or reversed.
    CREATE OR REPLACE FUNCTION hafapass_require_inserted_payout_custody() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF EXISTS (SELECT 1 FROM payouts p WHERE p.id = NEW.id AND p.status IN (2, 4))
          AND NOT EXISTS (SELECT 1 FROM payout_custody_determinations d
            WHERE d.payout_id = NEW.id AND d.settlement_id = (SELECT p.settlement_id FROM payouts p WHERE p.id = NEW.id)) THEN
        RAISE EXCEPTION 'Payout custody fence: payout % was inserted paid without a custody determination; record it paid from the current release', NEW.id
          USING ERRCODE = '23514';
      END IF;
      RETURN NULL;
    END;
    $$;
    DROP TRIGGER IF EXISTS payouts_require_custody_on_insert ON payouts;
    CREATE CONSTRAINT TRIGGER payouts_require_custody_on_insert AFTER INSERT ON payouts
      DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.status IN (2, 4))
      EXECUTE FUNCTION hafapass_require_inserted_payout_custody();

    CREATE OR REPLACE FUNCTION hafapass_check_custody_determination() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      payout_status integer;
      payout_settlement bigint;
    BEGIN
      -- The payout row first, in its own statement (CodeRabbit 4705527070,
      -- hafapass_guard_payout_settlement): then the current version.
      PERFORM 1 FROM payouts WHERE id = NEW.payout_id FOR NO KEY UPDATE;
      SELECT status, settlement_id INTO payout_status, payout_settlement FROM payouts WHERE id = NEW.payout_id;
      IF payout_settlement IS DISTINCT FROM NEW.settlement_id THEN
        RAISE EXCEPTION 'A custody determination must name its payout''s own settlement version' USING ERRCODE = '23514';
      END IF;
      IF NEW.basis = 'recorded_at_paid' AND payout_status NOT IN
          (0, 1, 5) THEN
        RAISE EXCEPTION 'A paid-recording custody determination is written only with the paid recording' USING ERRCODE = '23514';
      END IF;
      IF NEW.basis = 'derived_history' AND (payout_status NOT IN (2, 4)
          OR current_setting('hafapass.custody_derivation', true) IS DISTINCT FROM NEW.payout_id::text) THEN
        RAISE EXCEPTION 'A historical custody determination needs the authorized derivation for a paid payout'
          USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS payout_custody_determinations_check ON payout_custody_determinations;
    CREATE TRIGGER payout_custody_determinations_check BEFORE INSERT ON payout_custody_determinations
      FOR EACH ROW EXECUTE FUNCTION hafapass_check_custody_determination();

    CREATE OR REPLACE FUNCTION hafapass_check_custody_commit() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM payouts p WHERE p.id = NEW.payout_id
          AND p.status IN (2, 4)) THEN
        RAISE EXCEPTION 'A custody determination commits only with its payout recorded paid' USING ERRCODE = '23514';
      END IF;
      RETURN NULL;
    END;
    $$;
    DROP TRIGGER IF EXISTS payout_custody_determinations_commit ON payout_custody_determinations;
    CREATE CONSTRAINT TRIGGER payout_custody_determinations_commit AFTER INSERT ON payout_custody_determinations
      DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION hafapass_check_custody_commit();

    -- A2 recheck finding 1 (758485ae): the accepted-transfer rule for every
    -- writer and every event (A1 during the overlap or after a code
    -- rollback, raw SQL). A transfer the provider accepted after a fence,
    -- guard or hold refused it (PayoutCreator#record_refused_paid_locked!)
    -- carries payouts.provider_accepted_at, the provider's reported paid time
    -- or, when its result reported none, when this release observed it
    -- (provider_accepted_basis says which; CodeRabbit 4706251665): a
    -- durable, non-personal marker that audit redaction never touches. From
    -- then on its money is out with the organizer, so its reservation stays
    -- committed: it stays processing or held (held from processing, under
    -- its provider conflict), is never recorded paid (an ordinary paid
    -- payout would book it twice), failed or pending (which free or resend
    -- it), never deleted, and keeps its identity, amounts and version. It
    -- becomes reversed only after finance recorded the acceptance
    -- (accepted_transfer_recorded_at, stamped here once, so CPA books the
    -- outgoing transfer before its return) and, checked at commit by
    -- hafapass_check_payout_reversal, with the exact verified return of
    -- that acceptance. A reversed one stays reversed. Payouts the provider
    -- never accepted keep every existing rule.
    CREATE OR REPLACE FUNCTION hafapass_guard_accepted_transfer() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Accepted transfer fence: payout % is a transfer the provider accepted; it is never deleted', OLD.id
          USING ERRCODE = '23514';
      END IF;
      IF TG_OP = 'INSERT' THEN
        RAISE EXCEPTION 'Accepted transfer fence: a provider''s acceptance is recorded only on the payout that was submitted'
          USING ERRCODE = '23514';
      END IF;
      IF OLD.provider_accepted_at IS NULL THEN
        IF NEW.provider_accepted_at IS NULL OR NEW.provider_accepted_basis IS NULL OR NEW.accepted_transfer_recorded_at IS NOT NULL
            OR NEW.status NOT IN (1, 5) OR NEW.provider_payout_id IS NULL
            OR NEW.failure_code IS DISTINCT FROM 'provider_result_conflict'
            OR (NEW.status = 5 AND NEW.held_from_status IS DISTINCT FROM 'processing') THEN
          RAISE EXCEPTION 'Accepted transfer fence: payout % records a provider''s acceptance only in flight, with its transfer identifier and conflict', NEW.id
            USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END IF;
      IF NEW.provider_accepted_at IS DISTINCT FROM OLD.provider_accepted_at
          OR NEW.provider_accepted_basis IS DISTINCT FROM OLD.provider_accepted_basis
          OR NEW.provider_payout_id IS DISTINCT FROM OLD.provider_payout_id OR NEW.provider IS DISTINCT FROM OLD.provider
          OR NEW.amount_cents IS DISTINCT FROM OLD.amount_cents OR NEW.withheld_cents IS DISTINCT FROM OLD.withheld_cents
          OR NEW.carried_withholding_cents IS DISTINCT FROM OLD.carried_withholding_cents
          OR NEW.currency IS DISTINCT FROM OLD.currency OR NEW.settlement_id IS DISTINCT FROM OLD.settlement_id
          OR NEW.event_id IS DISTINCT FROM OLD.event_id OR NEW.organization_id IS DISTINCT FROM OLD.organization_id
          OR NEW.connected_account_id IS DISTINCT FROM OLD.connected_account_id
          OR NEW.idempotency_key IS DISTINCT FROM OLD.idempotency_key
          OR (OLD.accepted_transfer_recorded_at IS NOT NULL
            AND NEW.accepted_transfer_recorded_at IS DISTINCT FROM OLD.accepted_transfer_recorded_at) THEN
        RAISE EXCEPTION 'Accepted transfer fence: payout % is a transfer the provider accepted; its acceptance, transfer identifier, amounts and version are fixed', OLD.id
          USING ERRCODE = '23514';
      END IF;
      -- CodeRabbit 4706251703: finance's acknowledgement is stamped only by
      -- the current release's audited path, which names the payout
      -- (FinancialIntegrity.with_payout_acceptance, PayoutReconciler).
      IF OLD.accepted_transfer_recorded_at IS NULL AND NEW.accepted_transfer_recorded_at IS NOT NULL THEN
        IF current_setting('hafapass.payout_acceptance', true) IS DISTINCT FROM NEW.id::text THEN
          RAISE EXCEPTION 'Accepted transfer fence: payout % records finance''s acceptance only from the current release''s reconciler', OLD.id
            USING ERRCODE = '23514';
        END IF;
        NEW.accepted_transfer_recorded_at := timezone('UTC', clock_timestamp());
      END IF;
      IF OLD.status = 4 THEN
        IF NEW.status IS DISTINCT FROM OLD.status THEN
          RAISE EXCEPTION 'Accepted transfer fence: payout % was returned and stays reversed', OLD.id USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END IF;
      -- CodeRabbit 4706251703: the acceptance recorded by an earlier write
      -- (OLD), so one update cannot stamp it and reverse together.
      IF NEW.status = 4 THEN
        IF OLD.accepted_transfer_recorded_at IS NULL THEN
          RAISE EXCEPTION 'Accepted transfer fence: payout % is a transfer the provider accepted; record the accepted transfer before its return', OLD.id
            USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END IF;
      IF NEW.status NOT IN (1, 5)
          OR NEW.failure_code IS DISTINCT FROM 'provider_result_conflict'
          OR (NEW.status = 5 AND NEW.held_from_status IS DISTINCT FROM 'processing') THEN
        RAISE EXCEPTION 'Accepted transfer fence: payout % is a transfer the provider accepted; it is never recorded paid, failed, pending or released, and stays committed until the bank''s exact return', OLD.id
          USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS payouts_accepted_transfer_guard ON payouts;
    CREATE TRIGGER payouts_accepted_transfer_guard BEFORE UPDATE ON payouts
      FOR EACH ROW WHEN (OLD.provider_accepted_at IS NOT NULL OR NEW.provider_accepted_at IS NOT NULL
        OR NEW.accepted_transfer_recorded_at IS NOT NULL)
      EXECUTE FUNCTION hafapass_guard_accepted_transfer();
    DROP TRIGGER IF EXISTS payouts_accepted_transfer_guard_on_insert ON payouts;
    CREATE TRIGGER payouts_accepted_transfer_guard_on_insert BEFORE INSERT ON payouts
      FOR EACH ROW WHEN (NEW.provider_accepted_at IS NOT NULL OR NEW.accepted_transfer_recorded_at IS NOT NULL)
      EXECUTE FUNCTION hafapass_guard_accepted_transfer();
    DROP TRIGGER IF EXISTS payouts_accepted_transfer_guard_on_delete ON payouts;
    CREATE TRIGGER payouts_accepted_transfer_guard_on_delete BEFORE DELETE ON payouts
      FOR EACH ROW WHEN (OLD.provider_accepted_at IS NOT NULL)
      EXECUTE FUNCTION hafapass_guard_accepted_transfer();
  SQL

end
