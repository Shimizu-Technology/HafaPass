# frozen_string_literal: true

module Operations
  # One-time pre-launch reset: empties every business table so a database that
  # only ever held synthetic/test data can go live as production. Keeps schema
  # bookkeeping, site settings, runtime/queue infrastructure, and the users named
  # in KEEP_USER_EMAILS. Refuses (and changes nothing) if anything looks like
  # real money moved.
  class SyntheticDataPurge
    CONFIRMATION = "PURGE_SYNTHETIC_DATA"
    ACTION = "operations.synthetic_data_purged"
    SOURCE = "hafapass:purge_synthetic_data"
    KEPT_TABLES = %w[schema_migrations ar_internal_metadata site_settings users].freeze
    KEPT_TABLE_PREFIXES = %w[solid_queue_ solid_cache_ solid_cable_ runtime_].freeze
    MONEY_MOVEMENT_TABLES = %w[settlements settlement_items payouts].freeze
    LOCK_TIMEOUT = "15s"
    REPEAT_CONFIRMATION = "YES"
    QUEUE_JOBS_TABLE = "solid_queue_jobs"

    # [table, column, SQL predicate, description]. Each is checked only if the
    # table/column exists, so the guard survives schema changes.
    LIVE_MODE_CHECKS = [
      ["payments", "provider_environment", "provider_environment = 'live'", "payments charged in live mode"],
      ["payments", "provider_payload", "provider_payload ->> 'livemode' = 'true'", "payments with a livemode provider payload"],
      ["refunds", "provider_payload", "provider_payload ->> 'livemode' = 'true'", "refunds with a livemode provider payload"],
      ["disputes", "provider_payload", "provider_payload ->> 'livemode' = 'true'", "disputes with a livemode provider payload"],
      ["webhook_events", "payload", "payload ->> 'livemode' = 'true'", "livemode webhook events"],
      ["payment_events", "data", "data ->> 'livemode' = 'true'", "livemode payment events"],
      ["live_money_proof_authorizations", "consumed_at", "consumed_at IS NOT NULL", "consumed live-money proof authorizations"],
      # Clover rows carry no sandbox/live marker, so any completed or
      # unresolved card-present charge is treated as possibly real money.
      ["card_present_payment_attempts", "status", "status IN (1, 3)", "succeeded or result-unknown card-present payment attempts"]
    ].freeze

    class Refused < StandardError; end

    Result = Struct.new(:before_counts, :after_counts, :kept_user_emails, :deleted_user_count, :purged_tables,
      :deleted_queue_job_count, keyword_init: true)

    def self.call(confirm:, keep_user_emails:, allow_repeat: nil, out: $stdout)
      new(confirm: confirm, keep_user_emails: keep_user_emails, allow_repeat: allow_repeat, out: out).call
    end

    def initialize(confirm:, keep_user_emails:, allow_repeat: nil, out: $stdout)
      @confirm = confirm.to_s
      @allow_repeat = allow_repeat.to_s == REPEAT_CONFIRMATION
      @keep_user_emails = keep_user_emails.to_s.split(",").map { |email| email.strip.downcase }.reject(&:empty?).uniq
      @out = out
    end

    def call
      raise Refused, "Set CONFIRM=#{CONFIRMATION} to purge all business data." unless @confirm == CONFIRMATION
      raise Refused, "KEEP_USER_EMAILS is blank; list at least one user to keep (comma-separated)." if @keep_user_emails.empty?

      tables = purge_tables
      result = ActiveRecord::Base.transaction do
        lock!(tables)
        verify_kept_users!
        verify_not_repeated!
        verify_no_live_money!
        verify_no_money_movement!
        verify_no_kept_table_references!(tables)
        purge!(tables)
      end
      print_summary(result)
      result
    end

    private

    def connection
      ActiveRecord::Base.connection
    end

    def kept_table?(table)
      KEPT_TABLES.include?(table) || KEPT_TABLE_PREFIXES.any? { |prefix| table.start_with?(prefix) }
    end

    def purge_tables
      connection.tables.reject { |table| kept_table?(table) }.sort
    end

    # Table names come from the live schema and are always identifier-quoted;
    # no user input reaches these statements.
    def statement(command, tables, suffix)
      [command, tables.map { |table| connection.quote_table_name(table) }.join(", "), suffix].join(" ")
    end

    def lock!(tables)
      connection.execute("SET LOCAL lock_timeout = #{connection.quote(LOCK_TIMEOUT)}")
      connection.execute(statement("LOCK TABLE", tables, "IN ACCESS EXCLUSIVE MODE")) if tables.any?
      connection.execute("LOCK TABLE #{connection.quote_table_name('users')} IN EXCLUSIVE MODE")
    end

    def kept_users
      User.where("LOWER(email) IN (?)", @keep_user_emails)
    end

    def verify_kept_users!
      found = kept_users.pluck(Arel.sql("LOWER(email)")).uniq
      missing = @keep_user_emails - found
      raise Refused, "KEEP_USER_EMAILS lists emails with no matching user: #{missing.join(', ')}." if missing.any?
      return if kept_users.where(role: :admin).exists?

      raise Refused, "None of the KEEP_USER_EMAILS users is a platform admin; keep at least one admin."
    end

    # A second run would erase real activity recorded since the first purge.
    def verify_not_repeated!
      return if @allow_repeat

      if AuditLog.exists?(action: ACTION)
        raise Refused, "A synthetic-data purge already ran. Set ALLOW_REPEAT_PURGE=#{REPEAT_CONFIRMATION} to run it again."
      end
      return unless SiteSetting.instance.live_mode?

      raise Refused, "Payments are live. Set ALLOW_REPEAT_PURGE=#{REPEAT_CONFIRMATION} only if no real orders exist."
    end

    def verify_no_live_money!
      problems = LIVE_MODE_CHECKS.filter_map do |table, column, predicate, description|
        next unless connection.table_exists?(table) && connection.column_exists?(table, column)

        count = count_where(table, predicate)
        "#{count} #{description}" if count.positive?
      end
      return if problems.empty?

      raise Refused, "Live-mode money activity found (#{problems.join('; ')}). This data is not synthetic."
    end

    def verify_no_money_movement!
      problems = MONEY_MOVEMENT_TABLES.filter_map do |table|
        next unless connection.table_exists?(table)

        count = count_rows(table)
        "#{count} #{table}" if count.positive?
      end
      return if problems.empty?

      raise Refused, "Settlement/payout rows exist (#{problems.join(', ')}). Resolve them before purging."
    end

    # A kept table pointing at a purged one would either block the TRUNCATE or
    # (with CASCADE) be emptied too. TRUNCATE runs without CASCADE, so this is
    # a clear early message for what Postgres would otherwise reject.
    def verify_no_kept_table_references!(tables)
      purged = tables.to_set
      offending = foreign_keys.select { |from, to| !purged.include?(from) && purged.include?(to) }
      return if offending.empty?

      details = offending.map { |from, to| "#{from} -> #{to}" }.uniq.join(", ")
      raise Refused, "Kept tables reference purged tables (#{details}). Update the purge before running it."
    end

    def foreign_keys
      connection.select_rows(<<~SQL.squish)
        SELECT src.relname, dst.relname
        FROM pg_constraint con
        JOIN pg_class src ON src.oid = con.conrelid
        JOIN pg_class dst ON dst.oid = con.confrelid
        JOIN pg_namespace ns ON ns.oid = src.relnamespace
        WHERE con.contype = 'f' AND ns.nspname = current_schema()
      SQL
    end

    def purge!(tables)
      counted = tables + ["users"]
      before = row_counts(counted)
      # IDs keep counting up: email idempotency keys ("order-confirmation/<id>")
      # and job arguments must never point at a reused ID.
      connection.execute(statement("TRUNCATE", tables, "")) if tables.any?
      deleted_jobs = delete_pending_jobs!
      deleted_users = User.where("email IS NULL OR LOWER(email) NOT IN (?)", @keep_user_emails).delete_all
      after_purge = row_counts(counted)
      kept_emails = kept_users.order(:id).pluck(:email)

      AuditLogger.record!(
        action: ACTION,
        auditable: SiteSetting.instance,
        actor: nil,
        metadata: {
          source: SOURCE,
          purged_at: Time.current.iso8601,
          kept_user_emails: kept_emails,
          deleted_user_count: deleted_users,
          deleted_queue_job_count: deleted_jobs,
          purged_table_count: tables.size,
          row_counts_before: before.select { |_table, count| count.positive? },
          row_counts_after: after_purge.select { |table, _count| before[table].positive? }
        }
      )

      Result.new(before_counts: before, after_counts: row_counts(counted), kept_user_emails: kept_emails,
        deleted_user_count: deleted_users, purged_tables: tables, deleted_queue_job_count: deleted_jobs)
    end

    # Queued, scheduled, claimed, blocked or failed jobs may name purged rows.
    # Recurring jobs never carry business IDs.
    # Jobs created by recurring tasks are kept (with the task definitions);
    # execution rows cascade with their job.
    def delete_pending_jobs!
      return 0 unless connection.table_exists?(QUEUE_JOBS_TABLE)

      sql = "DELETE FROM #{connection.quote_table_name(QUEUE_JOBS_TABLE)}"
      if connection.table_exists?("solid_queue_recurring_executions")
        sql += " WHERE id NOT IN (SELECT job_id FROM solid_queue_recurring_executions)"
      end
      deleted = connection.delete(sql)
      # Concurrency semaphores count claims of the deleted jobs; clear them so
      # no concurrency key stays blocked. Blocked/ready/claimed/failed
      # executions cascade with their jobs.
      if connection.table_exists?("solid_queue_semaphores")
        connection.delete("DELETE FROM #{connection.quote_table_name('solid_queue_semaphores')}")
      end
      deleted
    end

    def row_counts(tables)
      tables.index_with { |table| count_rows(table) }
    end

    def count_rows(table)
      connection.select_value("SELECT COUNT(*) FROM #{connection.quote_table_name(table)}").to_i
    end

    def count_where(table, predicate)
      connection.select_value(Arel::Table.new(table).project(Arel.star.count).where(Arel.sql(predicate))).to_i
    end

    def print_summary(result)
      @out.puts "Purged #{result.purged_tables.size} tables; kept users: #{result.kept_user_emails.join(', ')}."
      @out.puts format("%-45s %10s %10s", "table", "before", "after")
      result.before_counts.each do |table, before|
        next unless before.positive?

        @out.puts format("%-45s %10d %10d", table, before, result.after_counts.fetch(table))
      end
      @out.puts format("%-45s %10d %10d", "TOTAL", result.before_counts.values.sum, result.after_counts.values.sum)
      @out.puts "Deleted #{result.deleted_user_count} users and #{result.deleted_queue_job_count} queued jobs. " \
        "Wrote one #{ACTION} audit log entry."
    end
  end
end
