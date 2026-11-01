# frozen_string_literal: true

# CompletePastEventsJob completes ended events on a schedule. Its state
# changes have no person behind them, so the actor becomes optional; the audit
# entry records the system source instead. Dropping NOT NULL is metadata-only.
class AllowSystemEventStateChanges < ActiveRecord::Migration[8.1]
  def change
    change_column_null :event_state_changes, :actor_user_id, true
  end
end
