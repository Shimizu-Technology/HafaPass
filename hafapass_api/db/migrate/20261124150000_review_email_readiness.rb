class ReviewEmailReadiness < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :audience_mailings, :filters, :jsonb, default: {}, null: false
    add_column :audience_mailings, :recipient_count, :integer, default: 0, null: false
    add_column :audience_mailings, :blocked_reason, :string
    add_index :message_deliveries, "lower(recipient)", name: "index_message_deliveries_lower_recipient", algorithm: :concurrently
  end
end
