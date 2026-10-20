# Each new order records who bears its actual card-processing cost. Existing
# orders keep NULL, which means the legacy rule (the organizer bears it), so
# their settlement statements and source digests are unchanged. The column is
# nullable with no default: adding it rewrites no rows and touches no
# updated_at watermark.
class SnapshotProcessingFeeBearerOnOrders < ActiveRecord::Migration[8.1]
  CONSTRAINT = "orders_processing_fee_bearer_snapshot_valid"

  def up
    add_column :orders, :processing_fee_bearer_snapshot, :string
    add_check_constraint :orders,
      "processing_fee_bearer_snapshot IS NULL OR processing_fee_bearer_snapshot IN ('platform', 'organizer')",
      name: CONSTRAINT, validate: false
    validate_check_constraint :orders, name: CONSTRAINT
  end

  def down
    # Dropping a recorded bearer would turn platform-bearer orders into legacy
    # orders and retroactively deduct processing from organizer proceeds.
    if select_value("SELECT 1 FROM orders WHERE processing_fee_bearer_snapshot IS NOT NULL LIMIT 1")
      raise ActiveRecord::IrreversibleMigration,
        "Orders have recorded processing-fee bearers; rolling back would restate their settlements"
    end

    remove_check_constraint :orders, name: CONSTRAINT
    remove_column :orders, :processing_fee_bearer_snapshot
  end
end
