# Non-transactional specs reset shared tables with TRUNCATE, including
# audit_logs, which the database refuses without the synthetic purge's opt-in.
# In tests only, a TRUNCATE naming audit_logs issued outside any transaction
# runs inside one with that opt-in. Inside a transaction (the purge itself and
# the guard specs) nothing changes, so the real guard is still exercised.
module AuditTruncateTestCleanup
  def execute(sql, *args, **kwargs)
    return super unless !transaction_open? && sql.is_a?(String) &&
      sql.match?(/\A\s*TRUNCATE\b/i) && sql.match?(/\baudit_logs\b/)

    transaction do
      super("SET LOCAL hafapass.audit_truncate = 'on'", *args, **kwargs)
      super(sql, *args, **kwargs)
    end
  end
end

ActiveSupport.on_load(:active_record_postgresqladapter) { prepend AuditTruncateTestCleanup }
