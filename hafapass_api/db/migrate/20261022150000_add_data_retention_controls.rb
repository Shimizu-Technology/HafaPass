class AddDataRetentionControls < ActiveRecord::Migration[8.0]
  def change
    add_column :site_settings, :retention_purge_enabled, :boolean, default: false, null: false

    create_table :legal_holds do |t|
      t.string :scope_type, null: false
      t.string :scope_value, null: false
      t.text :reason, null: false
      t.references :placed_by, null: false, foreign_key: { to_table: :users, on_delete: :restrict }
      t.references :released_by, foreign_key: { to_table: :users, on_delete: :restrict }
      t.datetime :released_at
      t.timestamps
    end
    add_index :legal_holds, [:scope_type, :scope_value], unique: true,
      where: "released_at IS NULL", name: "index_active_legal_holds_on_scope"

    create_table :privacy_requests do |t|
      t.string :kind, null: false
      t.string :status, default: "submitted", null: false
      t.references :user, foreign_key: { on_delete: :nullify }
      t.references :order, foreign_key: { on_delete: :restrict }
      t.string :requester_email, null: false
      t.references :verified_by, foreign_key: { to_table: :users, on_delete: :restrict }
      t.datetime :verified_at
      t.references :executed_by, foreign_key: { to_table: :users, on_delete: :restrict }
      t.datetime :executed_at
      t.jsonb :result, default: {}, null: false
      t.timestamps
    end
    add_index :privacy_requests, [:status, :created_at]

    add_reference :message_deliveries, :privacy_request, foreign_key: { on_delete: :restrict }
    remove_check_constraint :message_deliveries, name: "message_deliveries_subject_present"
    add_check_constraint :message_deliveries,
      "order_id IS NOT NULL OR ticket_id IS NOT NULL OR event_id IS NOT NULL OR organization_membership_id IS NOT NULL OR platform_invitation_id IS NOT NULL OR privacy_request_id IS NOT NULL",
      name: "message_deliveries_subject_present"
  end
end
