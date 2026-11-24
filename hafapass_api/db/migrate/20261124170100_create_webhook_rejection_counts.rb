# frozen_string_literal: true

# Provider webhooks rejected before a receipt is stored (bad signature, no
# secret configured). Only a counter per five-minute bucket: no payload, no
# headers, no address. Lets operations see a wrong webhook secret.
class CreateWebhookRejectionCounts < ActiveRecord::Migration[8.1]
  def change
    create_table :webhook_rejection_counts do |t|
      t.string :provider, null: false
      t.string :reason, null: false
      t.datetime :bucket_started_at, null: false
      t.integer :count, null: false, default: 0
      t.timestamps
    end
    add_index :webhook_rejection_counts, [:provider, :reason, :bucket_started_at], unique: true,
      name: "index_webhook_rejection_counts_on_bucket"
    add_index :webhook_rejection_counts, :bucket_started_at
    add_check_constraint :webhook_rejection_counts, "count >= 0", name: "webhook_rejection_counts_nonnegative"
  end
end
