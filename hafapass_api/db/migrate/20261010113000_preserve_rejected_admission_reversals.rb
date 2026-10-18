# frozen_string_literal: true

class PreserveRejectedAdmissionReversals < ActiveRecord::Migration[8.1]
  def up
    remove_index :admission_actions, name: "idx_admission_single_reversal"
    add_index :admission_actions, :reverses_action_id, name: "idx_admission_single_reversal",
      unique: true, where: "reverses_action_id IS NOT NULL AND result = 0"
  end

  def down
    duplicates = select_value(<<~SQL).to_i
      SELECT COUNT(*) FROM (
        SELECT reverses_action_id FROM admission_actions
        WHERE reverses_action_id IS NOT NULL
        GROUP BY reverses_action_id HAVING COUNT(*) > 1
      ) repeated_reversals
    SQL
    if duplicates.positive?
      raise ActiveRecord::IrreversibleMigration, "Cannot restore uniqueness without deleting admission reversal history"
    end

    remove_index :admission_actions, name: "idx_admission_single_reversal"
    add_index :admission_actions, :reverses_action_id, name: "idx_admission_single_reversal",
      unique: true, where: "reverses_action_id IS NOT NULL"
  end
end
