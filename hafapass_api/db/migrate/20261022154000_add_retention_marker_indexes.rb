class AddRetentionMarkerIndexes < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    %i[orders payouts organizer_tax_informations audit_logs message_deliveries
      tickets registration_responses ticket_transfers guest_list_entries support_notes admission_actions
      admission_manifests message_provider_events privacy_requests payments refunds disputes payment_events
      fee_components reconciliation_exceptions card_present_payment_attempts webhook_events].each do |table|
      add_index table, :retention_anonymized_at, algorithm: :concurrently, if_not_exists: true
    end
  end
end
