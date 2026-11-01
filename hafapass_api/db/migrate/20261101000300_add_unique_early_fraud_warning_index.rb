# frozen_string_literal: true

# One open-or-resolved reconciliation exception per Stripe early fraud warning.
# The created and updated webhooks for a warning can arrive concurrently; the
# second insert now fails and the processor updates the first instead.
# Early fraud warnings are new in this release, so no duplicates exist yet.
class AddUniqueEarlyFraudWarningIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = "index_reconciliation_exceptions_on_early_fraud_warning_id"

  def up
    existing = connection.indexes(:reconciliation_exceptions).find { |entry| entry.name == INDEX_NAME }
    return if existing&.valid?

    remove_index :reconciliation_exceptions, name: INDEX_NAME, algorithm: :concurrently if existing
    add_index :reconciliation_exceptions, "(details ->> 'warning_id')", name: INDEX_NAME, unique: true,
      where: "code = 'early_fraud_warning' AND details ? 'warning_id'", algorithm: :concurrently
  end

  def down
    remove_index :reconciliation_exceptions, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
  end
end
