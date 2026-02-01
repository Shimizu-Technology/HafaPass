class CreatePromoCodes < ActiveRecord::Migration[8.1]
  def change
    create_table :promo_codes do |t|
      t.references :event, null: false, foreign_key: true
      t.string     :code, null: false
      t.string     :discount_type, null: false, default: 'percentage'  # percentage | fixed
      t.integer    :discount_value, null: false  # percent (e.g. 20) or cents (e.g. 500)
      t.integer    :max_uses
      t.integer    :current_uses, null: false, default: 0
      t.datetime   :starts_at
      t.datetime   :expires_at
      t.boolean    :active, null: false, default: true
      t.timestamps
    end

    add_index :promo_codes, [:event_id, :code], unique: true
  end
end
