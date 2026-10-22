class AddFinancialRetentionMarkers < ActiveRecord::Migration[8.0]
  def change
    %i[payments refunds disputes payment_events fee_components reconciliation_exceptions
      card_present_payment_attempts webhook_events].each do |table|
      add_column table, :retention_anonymized_at, :datetime
      add_index table, :retention_anonymized_at
    end
  end
end
