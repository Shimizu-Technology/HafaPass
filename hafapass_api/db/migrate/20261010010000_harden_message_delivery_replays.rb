class HardenMessageDeliveryReplays < ActiveRecord::Migration[8.0]
  def up
    add_column :message_deliveries, :outbound_payload, :jsonb, null: false, default: {}
    add_column :message_deliveries, :provider_attempted_at, :datetime
    add_column :message_deliveries, :provider_outcome_unknown, :boolean, null: false, default: false
    add_column :message_deliveries, :send_lease_token, :string
    add_column :message_deliveries, :send_lease_expires_at, :datetime
    remove_check_constraint :message_deliveries, name: "message_deliveries_status_valid"
    add_check_constraint :message_deliveries, "status IN (0,1,2,3,4,5,6,7,8)", name: "message_deliveries_status_valid"
    execute <<~SQL
      UPDATE message_deliveries SET status = 8, suppressed_at = NULL
      WHERE template = 'event_reminder' AND status = 3
        AND last_error = 'Reminder was cancelled or rescheduled'
    SQL
  end

  def down
    if select_value("SELECT EXISTS (SELECT 1 FROM message_deliveries WHERE status = 8 OR provider_attempted_at IS NOT NULL OR outbound_payload != '{}'::jsonb)")
      raise ActiveRecord::IrreversibleMigration, "Prepared requests and cancelled delivery history must be preserved"
    end
    remove_check_constraint :message_deliveries, name: "message_deliveries_status_valid"
    add_check_constraint :message_deliveries, "status IN (0,1,2,3,4,5,6,7)", name: "message_deliveries_status_valid"
    remove_column :message_deliveries, :send_lease_expires_at
    remove_column :message_deliveries, :send_lease_token
    remove_column :message_deliveries, :provider_outcome_unknown
    remove_column :message_deliveries, :provider_attempted_at
    remove_column :message_deliveries, :outbound_payload
  end
end
