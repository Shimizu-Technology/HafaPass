# frozen_string_literal: true

class IndexOnlineDoorCheckoutSessions < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = "index_payments_on_stripe_checkout_session_id"

  def up
    status = pg_index_status(INDEX_NAME)
    return if status == :valid

    drop_concurrent_index(INDEX_NAME) if status == :invalid
    add_index :payments, :stripe_checkout_session_id,
      name: INDEX_NAME,
      unique: true,
      algorithm: :concurrently,
      where: "stripe_checkout_session_id IS NOT NULL"
  end

  def down
    return if pg_index_status(INDEX_NAME) == :missing

    drop_concurrent_index(INDEX_NAME)
  end

  private

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
