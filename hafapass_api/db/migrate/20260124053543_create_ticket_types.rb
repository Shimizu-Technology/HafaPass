class CreateTicketTypes < ActiveRecord::Migration[8.1]
  def change
    create_table :ticket_types do |t|
      t.references :event, null: false, foreign_key: true
      t.string :name, null: false
      t.text :description
      t.integer :price_cents
      t.integer :quantity_available
      t.integer :quantity_sold, default: 0, null: false
      t.integer :max_per_order, default: 10
      t.datetime :sales_start_at
      t.datetime :sales_end_at
      t.integer :sort_order, default: 0

      t.timestamps
    end
  end
end
