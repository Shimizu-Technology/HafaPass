class AddRetentionMarkersToRelatedRecords < ActiveRecord::Migration[8.0]
  def change
    %i[tickets registration_responses ticket_transfers guest_list_entries support_notes admission_actions
      admission_manifests message_provider_events privacy_requests].each do |table|
      add_column table, :retention_anonymized_at, :datetime
      add_index table, :retention_anonymized_at
    end
  end
end
