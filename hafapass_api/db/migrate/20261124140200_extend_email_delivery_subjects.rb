class ExtendEmailDeliverySubjects < ActiveRecord::Migration[8.1]
  def up
    add_check_constraint :message_deliveries,
      "order_id IS NOT NULL OR ticket_id IS NOT NULL OR event_id IS NOT NULL OR organization_membership_id IS NOT NULL OR platform_invitation_id IS NOT NULL OR privacy_request_id IS NOT NULL OR audience_mailing_id IS NOT NULL OR platform_subscriber_id IS NOT NULL",
      name: "message_deliveries_subject_present_email_base", validate: false
    remove_check_constraint :message_deliveries, name: "message_deliveries_subject_present_with_privacy"
    add_column :audience_mailings, :recipient_emails, :jsonb, default: [], null: false
  end

  def down
    if select_value(<<~SQL)
      SELECT 1 FROM message_deliveries
      WHERE order_id IS NULL AND ticket_id IS NULL AND event_id IS NULL
        AND organization_membership_id IS NULL AND platform_invitation_id IS NULL AND privacy_request_id IS NULL
      LIMIT 1
    SQL
      raise ActiveRecord::IrreversibleMigration,
        "Reconcile email-base-only message deliveries before rollback; the restored subject constraint would reject their updates"
    end

    add_check_constraint :message_deliveries,
      "order_id IS NOT NULL OR ticket_id IS NOT NULL OR event_id IS NOT NULL OR organization_membership_id IS NOT NULL OR platform_invitation_id IS NOT NULL OR privacy_request_id IS NOT NULL",
      name: "message_deliveries_subject_present_with_privacy", validate: false
    remove_check_constraint :message_deliveries, name: "message_deliveries_subject_present_email_base"
    # Rollback runs with the prior application version, which has no snapshot column.
    safety_assured { remove_column :audience_mailings, :recipient_emails }
  end
end
