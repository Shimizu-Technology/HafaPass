# frozen_string_literal: true

# Kept in the schema dump as executable DDL so db:schema:load/test:prepare has
# the same protection as a migrated production database.
module AuditLogIntegrity
  SQL = <<~SQL.freeze
    CREATE OR REPLACE FUNCTION hafapass_protect_audit_log() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Audit logs cannot be deleted' USING ERRCODE = '23514';
      END IF;
      IF current_setting('hafapass.audit_redaction', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION 'Audit logs are append-only' USING ERRCODE = '23514';
      END IF;
      IF (to_jsonb(NEW) - ARRAY['before_data','after_data','metadata','ip_address','retention_anonymized_at','updated_at'])
          IS DISTINCT FROM
         (to_jsonb(OLD) - ARRAY['before_data','after_data','metadata','ip_address','retention_anonymized_at','updated_at']) THEN
        RAISE EXCEPTION 'Audit identity cannot be redacted' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS audit_logs_append_only ON audit_logs;
    CREATE TRIGGER audit_logs_append_only BEFORE UPDATE OR DELETE ON audit_logs
      FOR EACH ROW EXECUTE FUNCTION hafapass_protect_audit_log();
  SQL

  module SchemaDump
    private

    def tables(stream)
      super
      return unless @connection.data_source_exists?("audit_logs")
      return unless @connection.select_value("SELECT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'audit_logs_append_only' AND tgrelid = 'audit_logs'::regclass)")

      stream.puts "  execute <<~SQL"
      AuditLogIntegrity::SQL.each_line { |line| stream.puts "    #{line}" }
      stream.puts "  SQL"
      stream.puts
    end
  end
end
