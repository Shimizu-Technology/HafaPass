# frozen_string_literal: true

class IndexReEntryFields < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    ensure_concurrent_index :tickets, [:event_id, :occupancy_state],
      name: "index_tickets_on_event_id_and_occupancy_state"
    ensure_concurrent_index :tickets, :last_entry_device_id,
      name: "index_tickets_on_last_entry_device_id",
      where: "last_entry_device_id IS NOT NULL"
    ensure_concurrent_index :admission_actions, [:event_id, :occupancy_day, :occurred_at],
      name: "index_admission_actions_on_event_day_occurred_at"
  end

  def down
    drop_concurrent_index_if_present "index_admission_actions_on_event_day_occurred_at"
    drop_concurrent_index_if_present "index_tickets_on_last_entry_device_id"
    drop_concurrent_index_if_present "index_tickets_on_event_id_and_occupancy_state"
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
