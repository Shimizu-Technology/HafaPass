# frozen_string_literal: true

require_relative "../../lib/audit_log_integrity"

class StrengthenAuditLogIntegrity < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    add_column :audit_logs, :event_id, :bigint
    # Existing rows deliberately remain unknown. We cannot infer whether an
    # old actorless row was a provider or system operation or whether it won.
    add_column :audit_logs, :source, :string
    add_column :audit_logs, :outcome, :string
    add_column :audit_logs, :deduplication_key, :string
    add_index :audit_logs, [:event_id, :occurred_at], algorithm: :concurrently
    add_index :audit_logs, [:action, :deduplication_key], unique: true,
      where: "deduplication_key IS NOT NULL", name: "idx_audit_logs_retry_key", algorithm: :concurrently
    add_check_constraint :audit_logs, "source IS NULL OR source IN ('user','system','provider','admin')",
      name: "audit_logs_source", validate: false
    add_check_constraint :audit_logs, "outcome IS NULL OR outcome IN ('requested','succeeded','failed','unknown')",
      name: "audit_logs_outcome", validate: false
    validate_check_constraint :audit_logs, name: "audit_logs_source"
    validate_check_constraint :audit_logs, name: "audit_logs_outcome"
    execute AuditLogIntegrity::SQL
    execute <<~SQL
      INSERT INTO audit_logs (action, auditable_type, auditable_id, source, outcome, before_data, after_data,
        metadata, occurred_at, created_at, updated_at, deduplication_key)
      VALUES ('platform.activity_logging_started', 'AuditLogRelease', 20261024100000, 'system', 'succeeded', '{}', '{}',
        '{"release":"audit-integrity-v1","history":"Earlier entries may be incomplete; no historical actors or values were reconstructed."}',
        CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, 'audit-integrity-v1')
      ON CONFLICT (action, deduplication_key) WHERE deduplication_key IS NOT NULL DO NOTHING
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Preserve audit identities and the release marker; deploy a forward fix"
  end
end
