class LinkEmailBaseDeliveries < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_reference :message_deliveries, :audience_mailing, index: { algorithm: :concurrently }
    add_reference :message_deliveries, :platform_subscriber, index: { algorithm: :concurrently }
    add_foreign_key :message_deliveries, :audience_mailings, validate: false
    add_foreign_key :message_deliveries, :platform_subscribers, validate: false
    validate_foreign_key :message_deliveries, :audience_mailings
    validate_foreign_key :message_deliveries, :platform_subscribers
  end
end
