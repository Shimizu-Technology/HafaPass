class AddPayoutWithholdingCarryAndCheckAdjustments < ActiveRecord::Migration[8.0]
  def change
    add_column :payouts, :under_withheld_cents, :integer, default: 0, null: false
    add_column :payouts, :carried_withholding_cents, :integer, default: 0, null: false
    add_check_constraint :payouts, "under_withheld_cents >= 0", name: "payouts_under_withheld_nonnegative"
    add_check_constraint :payouts, "carried_withholding_cents >= 0", name: "payouts_carried_withholding_nonnegative"
    add_check_constraint :payouts, "withheld_cents + carried_withholding_cents <= amount_cents",
      name: "payouts_total_withholding_within_gross"

    create_table :payout_check_adjustments do |t|
      t.references :payout, null: false, foreign_key: true
      t.references :created_by_user, null: false, foreign_key: { to_table: :users }
      t.integer :amount_cents, null: false
      t.text :reason, null: false
      t.timestamps
    end
    add_check_constraint :payout_check_adjustments, "amount_cents <> 0", name: "payout_check_adjustments_nonzero"
  end
end
