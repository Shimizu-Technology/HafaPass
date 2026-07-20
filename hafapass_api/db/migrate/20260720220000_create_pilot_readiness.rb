# frozen_string_literal: true

class CreatePilotReadiness < ActiveRecord::Migration[8.1]
  def change
    add_reference :message_deliveries, :event, foreign_key: { on_delete: :restrict }
    add_column :message_deliveries, :provider, :string, null: false, default: "resend"
    add_column :message_deliveries, :idempotency_key, :string
    add_column :message_deliveries, :payload_digest, :string
    add_column :message_deliveries, :last_event_at, :datetime
    add_column :message_deliveries, :delivered_at, :datetime
    add_column :message_deliveries, :failed_at, :datetime
    add_column :message_deliveries, :bounced_at, :datetime
    add_column :message_deliveries, :complained_at, :datetime
    add_column :message_deliveries, :suppressed_at, :datetime
    add_column :message_deliveries, :metadata, :jsonb, null: false, default: {}
    reversible do |direction|
      direction.up do
        execute <<~SQL.squish
          UPDATE message_deliveries
          SET idempotency_key = 'legacy-message/' || id::text
          WHERE idempotency_key IS NULL
        SQL
      end
    end
    change_column_null :message_deliveries, :idempotency_key, false
    add_index :message_deliveries, :idempotency_key, unique: true
    add_index :message_deliveries, [:status, :updated_at]
    add_index :message_deliveries, :provider_id
    remove_check_constraint :message_deliveries, "status IN (0, 1, 2, 3)",
      name: "message_deliveries_status_valid"
    remove_check_constraint :message_deliveries, "order_id IS NOT NULL OR ticket_id IS NOT NULL",
      name: "message_deliveries_subject_present"
    add_check_constraint :message_deliveries, "status IN (0, 1, 2, 3, 4, 5, 6, 7)",
      name: "message_deliveries_status_valid"
    add_check_constraint :message_deliveries,
      "order_id IS NOT NULL OR ticket_id IS NOT NULL OR event_id IS NOT NULL",
      name: "message_deliveries_subject_present"

    create_table :message_provider_events do |t|
      t.references :message_delivery, foreign_key: { on_delete: :nullify }
      t.string :provider, null: false, default: "resend"
      t.string :provider_event_id, null: false
      t.string :provider_message_id
      t.string :event_type, null: false
      t.datetime :occurred_at, null: false
      t.datetime :received_at, null: false
      t.datetime :processed_at
      t.jsonb :payload, null: false, default: {}
      t.text :processing_error
      t.timestamps
    end
    add_index :message_provider_events, [:provider, :provider_event_id], unique: true,
      name: "index_message_provider_events_on_provider_event"
    add_index :message_provider_events, [:provider_message_id, :occurred_at]

    create_table :support_notes do |t|
      t.references :author_user, null: false, foreign_key: { to_table: :users, on_delete: :restrict }
      t.references :order, foreign_key: { on_delete: :restrict }
      t.references :ticket, foreign_key: { on_delete: :restrict }
      t.references :event, foreign_key: { on_delete: :restrict }
      t.text :body, null: false
      t.timestamps
    end
    add_check_constraint :support_notes,
      "order_id IS NOT NULL OR ticket_id IS NOT NULL OR event_id IS NOT NULL",
      name: "support_notes_subject_present"
    add_index :support_notes, [:order_id, :created_at]
    add_index :support_notes, [:ticket_id, :created_at]
    add_index :support_notes, [:event_id, :created_at]

    add_column :organizer_profiles, :policy_version, :string
    add_column :organizer_profiles, :policy_digest, :string

    add_column :orders, :buyer_terms_version, :string
    add_column :orders, :buyer_terms_digest, :string
    add_column :orders, :buyer_terms_accepted_at, :datetime
  end
end
