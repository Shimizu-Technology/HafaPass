# frozen_string_literal: true

class ValidateReEntryCutoffTime < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    validate_check_constraint :events, name: "events_re_entry_cutoff_time_valid"
  end

  def down
    # Check constraint stays valid when rolling back only the validation step.
  end
end
