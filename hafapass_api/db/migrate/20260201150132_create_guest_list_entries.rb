class CreateGuestListEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :guest_list_entries do |t|
      t.references :event, null: false, foreign_key: true
      t.references :ticket_type, null: false, foreign_key: true
      t.string     :guest_name, null: false
      t.string     :guest_email
      t.string     :guest_phone
      t.string     :notes
      t.integer    :quantity, null: false, default: 1
      t.boolean    :redeemed, null: false, default: false
      t.references :order, null: true, foreign_key: true   # linked after redemption
      t.string     :added_by  # organizer email who added
      t.timestamps
    end

    add_index :guest_list_entries, [:event_id, :guest_email]
  end
end
