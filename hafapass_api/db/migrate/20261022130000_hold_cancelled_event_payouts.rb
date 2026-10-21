class HoldCancelledEventPayouts < ActiveRecord::Migration[8.0]
  def change
    remove_check_constraint :payouts, "status IN (0, 1, 2, 3, 4)", name: "payouts_status_valid"
    add_check_constraint :payouts, "status IN (0, 1, 2, 3, 4, 5)", name: "payouts_status_valid"
  end
end
