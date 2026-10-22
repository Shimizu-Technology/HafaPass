class AddRetentionAnonymizedAt < ActiveRecord::Migration[8.0]
  def change
    %i[orders payouts organizer_tax_informations audit_logs message_deliveries].each do |table|
      add_column table, :retention_anonymized_at, :datetime
      add_index table, :retention_anonymized_at
    end
  end
end
