class IndexMarketingConsentOrders < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_index :orders, "LOWER(buyer_email), event_id, created_at DESC, id DESC",
      name: "index_orders_on_event_and_consent_email", algorithm: :concurrently
  end
end
