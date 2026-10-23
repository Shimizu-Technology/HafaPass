# frozen_string_literal: true

class PreserveAuditActorAndFailureMarkers < ActiveRecord::Migration[8.0]
  def up
    # Historical IDs are immutable and may outlive the account they identify.
    remove_foreign_key :audit_logs, column: :actor_user_id

    create_table :audit_write_failures do |t|
      t.string :action, null: false
      t.string :auditable_type, null: false
      t.bigint :auditable_id, null: false
      t.bigint :organization_id
      t.bigint :event_id
      t.bigint :actor_user_id
      t.string :source, null: false
      t.string :failure_class, null: false
      t.timestamps
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Preserve historical actor identities and audit gap markers"
  end
end
