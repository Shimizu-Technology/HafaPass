class CreatePayoutLineAllocations < ActiveRecord::Migration[8.0]
  def change
    create_table :payout_line_allocations do |t|
      t.references :payout, null: false, foreign_key: true
      t.references :order_item, null: false, foreign_key: true
      t.integer :amount_cents, null: false
      t.timestamps
    end
    add_index :payout_line_allocations, [:payout_id, :order_item_id], unique: true
    add_check_constraint :payout_line_allocations, "amount_cents >= 0", name: "payout_line_allocations_nonnegative"
  end
end
