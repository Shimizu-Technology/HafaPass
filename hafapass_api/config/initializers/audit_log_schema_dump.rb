# frozen_string_literal: true

require Rails.root.join("lib/audit_log_integrity")
require Rails.root.join("lib/financial_integrity")
require "active_record/schema_dumper"
require "active_record/connection_adapters/abstract/schema_dumper"
require "active_record/connection_adapters/postgresql/schema_dumper"

ActiveRecord::ConnectionAdapters::PostgreSQL::SchemaDumper.prepend(AuditLogIntegrity::SchemaDump)
# Prepended second, so its DDL follows the audit-log DDL in the dump.
ActiveRecord::ConnectionAdapters::PostgreSQL::SchemaDumper.prepend(FinancialIntegrity::SchemaDump)
