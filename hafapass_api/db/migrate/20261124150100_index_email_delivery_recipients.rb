# frozen_string_literal: true

class IndexEmailDeliveryRecipients < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = "index_message_deliveries_lower_recipient"

  def up
    invalid = connection.select_value(<<~SQL)
      SELECT NOT indisvalid FROM pg_index
      WHERE indexrelid = to_regclass('#{INDEX_NAME}')
    SQL
    remove_index :message_deliveries, name: INDEX_NAME, algorithm: :concurrently if invalid
    add_index :message_deliveries, "lower(recipient)", name: INDEX_NAME, algorithm: :concurrently, if_not_exists: true
  end

  def down
    remove_index :message_deliveries, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
  end
end
