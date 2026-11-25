# frozen_string_literal: true

class AddReEntryCutoffTime < ActiveRecord::Migration[8.1]
  def up
    add_column :events, :re_entry_cutoff_time, :string
    add_check_constraint :events,
      "re_entry_cutoff_time IS NULL OR re_entry_cutoff_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'",
      name: "events_re_entry_cutoff_time_valid",
      validate: false
  end

  def down
    remove_check_constraint :events, name: "events_re_entry_cutoff_time_valid", if_exists: true
    remove_column :events, :re_entry_cutoff_time
  end
end
