# frozen_string_literal: true

require_relative "../../lib/audit_log_integrity"

class BlockAuditLogTruncate < ActiveRecord::Migration[8.1]
  def up
    # One function plus a statement-level trigger; CREATE OR REPLACE TRIGGER
    # takes a brief SHARE ROW EXCLUSIVE lock, bounded by lock_timeout.
    safety_assured { execute AuditLogIntegrity::TRUNCATE_SQL }
  end

  def down
    safety_assured do
      execute "DROP TRIGGER IF EXISTS audit_logs_no_truncate ON audit_logs"
      execute "DROP FUNCTION IF EXISTS hafapass_protect_audit_log_truncate()"
    end
  end
end
