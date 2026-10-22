class AddRetentionAnonymizedAt < ActiveRecord::Migration[8.0]
  def change
    %i[orders payouts organizer_tax_informations audit_logs message_deliveries].each do |table|
      add_column table, :retention_anonymized_at, :datetime
    end
  end
end
