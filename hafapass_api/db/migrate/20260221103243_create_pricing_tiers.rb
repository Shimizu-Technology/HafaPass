class CreatePricingTiers < ActiveRecord::Migration[8.1]
  def change
    create_table :pricing_tiers do |t|
      t.references :ticket_type, null: false, foreign_key: true
      t.string :name
      t.integer :price_cents
      t.integer :tier_type
      t.integer :quantity_limit
      t.integer :quantity_sold, default: 0, null: false
      t.datetime :starts_at
      t.datetime :ends_at
      t.integer :position, default: 0, null: false

      t.timestamps
    end
  end
end
