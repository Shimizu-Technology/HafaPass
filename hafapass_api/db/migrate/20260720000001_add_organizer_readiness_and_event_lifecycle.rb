class AddOrganizerReadinessAndEventLifecycle < ActiveRecord::Migration[8.0]
  def change
    add_column :organizer_profiles, :verification_status, :integer, null: false, default: 0
    add_column :organizer_profiles, :verification_requested_at, :datetime
    add_column :organizer_profiles, :verified_at, :datetime
    add_column :organizer_profiles, :verification_notes, :text
    add_column :organizer_profiles, :policy_accepted_at, :datetime
    add_column :organizer_profiles, :payout_ready, :boolean, null: false, default: false
    add_reference :organizer_profiles, :verified_by_user, foreign_key: { to_table: :users }

    create_table :event_state_changes do |t|
      t.references :event, null: false, foreign_key: true
      t.references :actor_user, null: false, foreign_key: { to_table: :users }
      t.string :action, null: false
      t.string :from_status, null: false
      t.string :to_status, null: false
      t.text :reason
      t.jsonb :metadata, null: false, default: {}
      t.datetime :occurred_at, null: false
      t.timestamps
    end

    add_index :event_state_changes, [:event_id, :occurred_at]
    add_index :organizer_profiles, :verification_status
  end
end
