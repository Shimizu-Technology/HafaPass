# frozen_string_literal: true

# Every ticket type now caps tickets per order (default 10). A blank limit used
# to mean "no limit", which let one checkout hold a whole ticket type.
class RequireTicketTypeMaxPerOrder < ActiveRecord::Migration[8.1]
  DEFAULT_MAX_PER_ORDER = 10

  def up
    execute "UPDATE ticket_types SET max_per_order = #{DEFAULT_MAX_PER_ORDER} WHERE max_per_order IS NULL"
    change_column_default :ticket_types, :max_per_order, DEFAULT_MAX_PER_ORDER
    change_column_null :ticket_types, :max_per_order, false
  end

  # The backfilled limits stay; reverting only allows a blank limit again.
  def down
    change_column_null :ticket_types, :max_per_order, true
  end
end
