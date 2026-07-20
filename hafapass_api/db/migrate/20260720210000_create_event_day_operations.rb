# frozen_string_literal: true

class CreateEventDayOperations < ActiveRecord::Migration[8.1]
  def change
    create_table :scanner_devices do |t|
      t.references :organization, null: false, foreign_key: { on_delete: :restrict }
      t.references :event, null: false, foreign_key: { on_delete: :restrict }
      t.references :user, null: false, foreign_key: { on_delete: :restrict }
      t.string :identifier, null: false
      t.string :name, null: false
      t.integer :status, null: false, default: 0
      t.datetime :authorization_expires_at, null: false
      t.datetime :revoked_at
      t.integer :last_manifest_version, null: false, default: 0
      t.string :last_manifest_digest
      t.datetime :manifest_downloaded_at
      t.datetime :last_synced_at
      t.datetime :last_seen_at
      t.integer :last_sequence, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :scanner_devices, [:event_id, :identifier], unique: true
    add_index :scanner_devices, [:event_id, :status]
    add_check_constraint :scanner_devices, "status IN (0, 1)", name: "scanner_devices_status_valid"
    add_check_constraint :scanner_devices, "last_manifest_version >= 0", name: "scanner_devices_manifest_version_nonnegative"
    add_check_constraint :scanner_devices, "last_sequence >= 0", name: "scanner_devices_sequence_nonnegative"

    create_table :admission_manifests do |t|
      t.references :organization, null: false, foreign_key: { on_delete: :restrict }
      t.references :event, null: false, foreign_key: { on_delete: :restrict }
      t.references :generated_by_user, foreign_key: { to_table: :users, on_delete: :restrict }
      t.integer :version, null: false
      t.string :source_digest, null: false
      t.string :digest, null: false
      t.text :signature, null: false
      t.string :key_id, null: false
      t.string :algorithm, null: false, default: "PS256"
      t.jsonb :payload, null: false, default: {}
      t.integer :ticket_count, null: false, default: 0
      t.datetime :generated_at, null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :admission_manifests, [:event_id, :version], unique: true
    add_index :admission_manifests, [:event_id, :source_digest]
    add_index :admission_manifests, :digest, unique: true
    add_check_constraint :admission_manifests, "version > 0", name: "admission_manifests_version_positive"
    add_check_constraint :admission_manifests, "ticket_count >= 0", name: "admission_manifests_ticket_count_nonnegative"

    create_table :admission_actions do |t|
      t.references :organization, null: false, foreign_key: { on_delete: :restrict }
      t.references :event, null: false, foreign_key: { on_delete: :restrict }
      t.references :ticket, foreign_key: { on_delete: :restrict }
      t.references :scanner_device, foreign_key: { on_delete: :restrict }
      t.references :actor_user, foreign_key: { to_table: :users, on_delete: :restrict }
      t.references :reverses_action, foreign_key: { to_table: :admission_actions, on_delete: :restrict }
      t.string :action_uuid, null: false
      t.integer :kind, null: false
      t.integer :source, null: false
      t.integer :result, null: false
      t.string :reason_code, null: false
      t.string :credential_hash
      t.integer :manifest_version
      t.integer :sequence
      t.datetime :occurred_at, null: false
      t.datetime :received_at, null: false
      t.jsonb :attendee_snapshot, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :admission_actions, :action_uuid, unique: true
    add_index :admission_actions, [:event_id, :occurred_at]
    add_index :admission_actions, [:event_id, :result]
    add_index :admission_actions, [:scanner_device_id, :sequence], unique: true,
      where: "scanner_device_id IS NOT NULL AND sequence IS NOT NULL", name: "idx_admission_device_sequence"
    add_index :admission_actions, :reverses_action_id, unique: true,
      where: "reverses_action_id IS NOT NULL", name: "idx_admission_single_reversal"
    add_check_constraint :admission_actions, "kind IN (0, 1)", name: "admission_actions_kind_valid"
    add_check_constraint :admission_actions, "source IN (0, 1, 2)", name: "admission_actions_source_valid"
    add_check_constraint :admission_actions, "result IN (0, 1, 2)", name: "admission_actions_result_valid"
    add_check_constraint :admission_actions, "manifest_version IS NULL OR manifest_version > 0",
      name: "admission_actions_manifest_version_positive"
    add_check_constraint :admission_actions, "sequence IS NULL OR sequence > 0",
      name: "admission_actions_sequence_positive"

    create_table :card_present_accounts do |t|
      t.references :organization, null: false, index: false, foreign_key: { on_delete: :restrict }
      t.references :verified_by_user, foreign_key: { to_table: :users, on_delete: :restrict }
      t.string :provider, null: false, default: "boh_clover"
      t.integer :status, null: false, default: 0
      t.string :merchant_id
      t.string :device_id
      t.string :pos_id
      t.integer :connection_mode, null: false, default: 0
      t.jsonb :verification_evidence, null: false, default: {}
      t.datetime :verified_at
      t.datetime :last_seen_at
      t.timestamps
    end
    add_index :card_present_accounts, :organization_id, unique: true
    add_index :card_present_accounts, [:provider, :merchant_id], unique: true,
      where: "merchant_id IS NOT NULL", name: "idx_card_present_provider_merchant"
    add_check_constraint :card_present_accounts, "status IN (0, 1, 2)", name: "card_present_accounts_status_valid"
    add_check_constraint :card_present_accounts, "connection_mode IN (0, 1)",
      name: "card_present_accounts_connection_mode_valid"

    create_table :card_present_payment_attempts do |t|
      t.references :organization, null: false, foreign_key: { on_delete: :restrict }
      t.references :event, null: false, foreign_key: { on_delete: :restrict }
      t.references :order, null: false, foreign_key: { on_delete: :restrict }
      t.references :payment, null: false, foreign_key: { on_delete: :restrict }
      t.references :card_present_account, null: false, foreign_key: { on_delete: :restrict }
      t.references :initiated_by_user, null: false, foreign_key: { to_table: :users, on_delete: :restrict }
      t.string :provider, null: false
      t.string :idempotency_key, null: false
      t.string :external_payment_id, null: false
      t.string :provider_payment_id
      t.integer :amount_cents, null: false
      t.string :currency, null: false, default: "usd"
      t.integer :status, null: false, default: 0
      t.string :failure_code
      t.text :failure_message
      t.jsonb :provider_response, null: false, default: {}
      t.datetime :initiated_at, null: false
      t.datetime :completed_at
      t.timestamps
    end
    add_index :card_present_payment_attempts, :idempotency_key, unique: true
    add_index :card_present_payment_attempts, :external_payment_id, unique: true
    add_index :card_present_payment_attempts, [:provider, :provider_payment_id], unique: true,
      where: "provider_payment_id IS NOT NULL", name: "idx_card_present_unique_provider_payment"
    add_index :card_present_payment_attempts, [:event_id, :status]
    add_check_constraint :card_present_payment_attempts, "amount_cents > 0",
      name: "card_present_attempts_amount_positive"
    add_check_constraint :card_present_payment_attempts, "char_length(currency) = 3",
      name: "card_present_attempts_currency_length"
    add_check_constraint :card_present_payment_attempts, "status IN (0, 1, 2, 3)",
      name: "card_present_attempts_status_valid"

    add_column :ticket_types, :door_allocation, :integer
    add_check_constraint :ticket_types, "door_allocation IS NULL OR door_allocation >= 0",
      name: "ticket_types_door_allocation_nonnegative"
  end
end
