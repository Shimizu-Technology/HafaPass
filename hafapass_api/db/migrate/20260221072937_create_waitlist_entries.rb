class CreateWaitlistEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :waitlist_entries do |t|
      t.references :event, null: false, foreign_key: true
      t.references :ticket_type, foreign_key: true
      t.string :email, null: false
      t.string :name
      t.string :phone
      t.integer :quantity, default: 1, null: false
      t.integer :position, null: false
      t.integer :status, default: 0, null: false
      t.datetime :notified_at
      t.datetime :expires_at
      t.references :user, foreign_key: true

      t.timestamps
    end

    add_index :waitlist_entries, [:event_id, :ticket_type_id, :email], unique: true, name: "idx_waitlist_unique_entry"
    add_index :waitlist_entries, [:event_id, :ticket_type_id, :position]
  end
end
