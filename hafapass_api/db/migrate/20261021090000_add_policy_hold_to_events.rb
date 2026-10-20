# frozen_string_literal: true

# A platform-admin policy hold stops sales (and optionally hides the event)
# without changing its lifecycle status, deleting data or refunding anyone.
# It is separate from the organizer's seating sales suspension so neither
# side can lift the other's pause. Existing events have no hold.
class AddPolicyHoldToEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :events, :policy_hold_at, :datetime
    add_column :events, :policy_hold_scope, :string
    add_column :events, :policy_hold_reason, :text
    add_reference :events, :policy_hold_by_user, foreign_key: { to_table: :users }, index: false
    add_index :events, :policy_hold_at, where: "policy_hold_at IS NOT NULL"
    add_check_constraint :events,
      "(policy_hold_at IS NULL AND policy_hold_scope IS NULL AND policy_hold_reason IS NULL) OR " \
      "(policy_hold_at IS NOT NULL AND policy_hold_scope IN ('sales', 'hidden') AND char_length(btrim(policy_hold_reason)) > 0)",
      name: "events_policy_hold_consistent"
  end
end
