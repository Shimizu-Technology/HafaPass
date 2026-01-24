class CreateTickets < ActiveRecord::Migration[8.1]
  def change
    create_table :tickets do |t|
      t.references :order, null: false, foreign_key: true
      t.references :ticket_type, null: false, foreign_key: true
      t.references :event, null: false, foreign_key: true
      t.string :qr_code
      t.integer :status, null: false, default: 0
      t.string :attendee_name
      t.string :attendee_email
      t.datetime :checked_in_at

      t.timestamps
    end

    add_index :tickets, :qr_code, unique: true
  end
end
