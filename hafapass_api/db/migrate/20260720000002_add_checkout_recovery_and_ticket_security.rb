# frozen_string_literal: true

class AddCheckoutRecoveryAndTicketSecurity < ActiveRecord::Migration[8.1]
  def up
    add_column :orders, :reference, :string
    add_column :orders, :guest_access_version, :integer, default: 1, null: false
    add_column :orders, :guest_access_expires_at, :datetime
    add_column :orders, :guest_access_revoked_at, :datetime
    add_index :orders, :reference, unique: true
    add_check_constraint :orders, "guest_access_version > 0", name: "orders_guest_access_version_positive"

    Order.reset_column_information
    Order.find_each do |order|
      order.update_columns(reference: unique_order_reference(order.id))
    end
    change_column_null :orders, :reference, false

    add_column :tickets, :display_credential_version, :integer, default: 1, null: false
    add_column :tickets, :scan_credential_version, :integer, default: 1, null: false
    add_column :tickets, :cancelled_at, :datetime
    add_column :tickets, :cancellation_reason, :string
    add_check_constraint :tickets, "display_credential_version > 0", name: "tickets_display_version_positive"
    add_check_constraint :tickets, "scan_credential_version > 0", name: "tickets_scan_version_positive"

    add_column :ticket_types, :max_per_buyer, :integer
    add_check_constraint :ticket_types, "max_per_buyer IS NULL OR max_per_buyer > 0", name: "ticket_types_max_per_buyer_positive"

    create_table :refund_tickets do |t|
      t.references :refund, null: false, foreign_key: { on_delete: :restrict }
      t.references :ticket, null: false, foreign_key: { on_delete: :restrict }, index: { unique: true }
      t.integer :amount_cents, null: false
      t.timestamps
    end
    add_check_constraint :refund_tickets, "amount_cents >= 0", name: "refund_tickets_amount_nonnegative"

    create_table :event_changes do |t|
      t.references :event, null: false, foreign_key: { on_delete: :restrict }
      t.references :actor_user, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :change_type, null: false
      t.string :reason
      t.jsonb :before_data, default: {}, null: false
      t.jsonb :after_data, default: {}, null: false
      t.datetime :occurred_at, null: false
      t.timestamps
    end
    add_index :event_changes, [:event_id, :occurred_at]

    create_table :event_change_responses do |t|
      t.references :event_change, null: false, foreign_key: { on_delete: :restrict }
      t.references :order, null: false, foreign_key: { on_delete: :restrict }
      t.string :decision, null: false
      t.datetime :responded_at, null: false
      t.timestamps
    end
    add_index :event_change_responses, [:event_change_id, :order_id], unique: true, name: "idx_event_change_responses_unique"

    create_table :disputes do |t|
      t.references :order, null: false, foreign_key: { on_delete: :restrict }
      t.references :payment, foreign_key: { on_delete: :restrict }
      t.string :provider, default: "stripe", null: false
      t.string :provider_dispute_id, null: false
      t.string :reason
      t.integer :amount_cents, null: false
      t.string :currency, default: "usd", null: false
      t.integer :status, default: 0, null: false
      t.datetime :opened_at, null: false
      t.datetime :closed_at
      t.jsonb :provider_payload, default: {}, null: false
      t.timestamps
    end
    add_index :disputes, [:provider, :provider_dispute_id], unique: true
    add_check_constraint :disputes, "amount_cents >= 0", name: "disputes_amount_nonnegative"
    add_check_constraint :disputes, "char_length(currency) = 3", name: "disputes_currency_length"
    add_check_constraint :disputes, "status IN (0, 1, 2)", name: "disputes_status_valid"

    create_table :message_deliveries do |t|
      t.references :order, foreign_key: { on_delete: :restrict }
      t.references :ticket, foreign_key: { on_delete: :restrict }
      t.references :requested_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :channel, default: "email", null: false
      t.string :template, null: false
      t.string :recipient, null: false
      t.string :provider_id
      t.integer :status, default: 0, null: false
      t.integer :attempts, default: 0, null: false
      t.text :last_error
      t.datetime :sent_at
      t.timestamps
    end
    add_index :message_deliveries, [:order_id, :created_at]
    add_check_constraint :message_deliveries, "status IN (0, 1, 2, 3)", name: "message_deliveries_status_valid"
    add_check_constraint :message_deliveries, "attempts >= 0", name: "message_deliveries_attempts_nonnegative"
    add_check_constraint :message_deliveries, "order_id IS NOT NULL OR ticket_id IS NOT NULL", name: "message_deliveries_subject_present"
  end

  def down
    drop_table :message_deliveries
    drop_table :disputes
    drop_table :event_change_responses
    drop_table :event_changes
    drop_table :refund_tickets
    remove_column :ticket_types, :max_per_buyer
    remove_column :tickets, :cancellation_reason
    remove_column :tickets, :cancelled_at
    remove_column :tickets, :scan_credential_version
    remove_column :tickets, :display_credential_version
    remove_column :orders, :guest_access_revoked_at
    remove_column :orders, :guest_access_expires_at
    remove_column :orders, :guest_access_version
    remove_column :orders, :reference
  end

  private

  def unique_order_reference(id)
    "HP-#{id.to_s(36).upcase.rjust(6, '0')}-#{SecureRandom.hex(2).upcase}"
  end
end
