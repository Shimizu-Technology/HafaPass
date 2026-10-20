# frozen_string_literal: true

class CreateWalletPasses < ActiveRecord::Migration[8.0]
  def change
    # One row per issued Apple pass serial or Google ticket object. A row is
    # bound to the scan credential version it was issued with, so a rotated,
    # transferred or cancelled ticket can void exactly the passes it replaced.
    create_table :wallet_passes do |t|
      t.references :ticket, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :serial_number, null: false
      t.integer :scan_credential_version, null: false
      # SHA-256 digests of the Apple authenticationTokens embedded in issued
      # copies; the raw tokens are never stored.
      t.string :authentication_token_digests, array: true, null: false, default: []
      t.string :content_digest
      t.datetime :content_updated_at
      t.string :synced_digest
      t.datetime :synced_at
      t.integer :sync_attempts, null: false, default: 0
      t.text :last_error
      t.timestamps
    end
    add_index :wallet_passes, [:provider, :serial_number], unique: true
    add_check_constraint :wallet_passes, "provider IN ('apple', 'google')", name: "wallet_passes_provider_known"

    create_table :apple_wallet_registrations do |t|
      t.references :wallet_pass, null: false, foreign_key: true
      t.string :device_library_identifier, null: false
      t.string :push_token, null: false
      t.timestamps
    end
    add_index :apple_wallet_registrations, [:device_library_identifier, :wallet_pass_id], unique: true,
      name: "index_apple_wallet_registrations_on_device_and_pass"
  end
end
