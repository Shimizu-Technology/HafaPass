class AddDataRetentionControls < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_column :site_settings, :retention_purge_enabled, :boolean, default: false, null: false

    create_table :legal_holds do |t|
      t.string :scope_type, null: false
      t.string :scope_value, null: false
      t.text :reason, null: false
      t.references :placed_by, null: false, index: false, foreign_key: { to_table: :users, on_delete: :restrict }
      t.references :released_by, index: false, foreign_key: { to_table: :users, on_delete: :restrict }
      t.datetime :released_at
      t.timestamps
    end
    add_index :legal_holds, :placed_by_id, algorithm: :concurrently
    add_index :legal_holds, :released_by_id, algorithm: :concurrently
    add_index :legal_holds, [:scope_type, :scope_value], algorithm: :concurrently, unique: true,
      where: "released_at IS NULL", name: "index_active_legal_holds_on_scope"

    create_table :privacy_requests do |t|
      t.string :kind, null: false
      t.string :status, default: "submitted", null: false
      t.references :user, index: false, foreign_key: { on_delete: :nullify }
      t.references :order, index: false, foreign_key: { on_delete: :restrict }
      t.string :requester_email, null: false
      t.references :verified_by, index: false, foreign_key: { to_table: :users, on_delete: :restrict }
      t.datetime :verified_at
      t.references :executed_by, index: false, foreign_key: { to_table: :users, on_delete: :restrict }
      t.datetime :executed_at
      t.jsonb :result, default: {}, null: false
      t.string :guest_challenge_digest
      t.datetime :guest_challenge_expires_at
      t.integer :guest_challenge_attempts, default: 0, null: false
      t.datetime :guest_challenge_passed_at
      t.timestamps
    end
    %i[user_id order_id verified_by_id executed_by_id].each do |column|
      add_index :privacy_requests, column, algorithm: :concurrently
    end
    add_index :privacy_requests, [:status, :created_at], algorithm: :concurrently

    add_reference :message_deliveries, :privacy_request, index: false
    add_foreign_key :message_deliveries, :privacy_requests, column: :privacy_request_id,
      on_delete: :restrict, validate: false
    validate_foreign_key :message_deliveries, :privacy_requests, column: :privacy_request_id
    add_index :message_deliveries, :privacy_request_id, algorithm: :concurrently
    add_check_constraint :message_deliveries,
      "order_id IS NOT NULL OR ticket_id IS NOT NULL OR event_id IS NOT NULL OR organization_membership_id IS NOT NULL OR platform_invitation_id IS NOT NULL OR privacy_request_id IS NOT NULL",
      name: "message_deliveries_subject_present_with_privacy", validate: false
    validate_check_constraint :message_deliveries, name: "message_deliveries_subject_present_with_privacy"
    remove_check_constraint :message_deliveries, name: "message_deliveries_subject_present"

    create_table :privacy_email_suppressions do |t|
      t.string :email_digest, null: false
      t.timestamps
    end
    add_index :privacy_email_suppressions, :email_digest, unique: true, algorithm: :concurrently
  end
end
