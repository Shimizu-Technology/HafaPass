# frozen_string_literal: true

# One refund per repayment operation. Resumable like IndexFulfillmentOwnership:
# a concurrent build interrupted by the release lock_timeout leaves an invalid
# index, which a rerun drops and rebuilds.
class IndexRefundRepaymentOperations < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    ensure_concurrent_index :refunds, :repayment_operation_id, name: "index_refunds_on_repayment_operation_id",
      unique: true, where: "repayment_operation_id IS NOT NULL"
  end

  def down
    drop_concurrent_index_if_present "index_refunds_on_repayment_operation_id"
  end

  private

  def ensure_concurrent_index(table, columns, name:, **options)
    status = pg_index_status(name)
    return if status == :valid

    drop_concurrent_index(name) if status == :invalid
    add_index table, columns, name: name, algorithm: :concurrently, **options
  end

  def drop_concurrent_index_if_present(name)
    return if pg_index_status(name) == :missing

    drop_concurrent_index(name)
  end

  def drop_concurrent_index(name)
    safety_assured do
      execute("DROP INDEX CONCURRENTLY IF EXISTS #{quote_table_name(name)}")
    end
  end

  def pg_index_status(name)
    sql = ActiveRecord::Base.sanitize_sql_array([
      <<~SQL.squish,
        SELECT i.indisvalid
        FROM pg_class c
        INNER JOIN pg_index i ON i.indexrelid = c.oid
        INNER JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = current_schema()
          AND c.relname = ?
          AND c.relkind = 'i'
        LIMIT 1
      SQL
      name
    ])
    value = select_value(sql)
    return :missing if value.nil?

    ActiveModel::Type::Boolean.new.cast(value) ? :valid : :invalid
  end
end
