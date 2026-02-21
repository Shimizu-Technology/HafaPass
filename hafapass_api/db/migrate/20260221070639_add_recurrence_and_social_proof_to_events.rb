class AddRecurrenceAndSocialProofToEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :events, :recurrence_rule, :string
    add_column :events, :recurrence_parent_id, :integer
    add_column :events, :recurrence_end_date, :date
    add_column :events, :show_attendees, :boolean, default: true
    add_index :events, :recurrence_parent_id
  end
end
