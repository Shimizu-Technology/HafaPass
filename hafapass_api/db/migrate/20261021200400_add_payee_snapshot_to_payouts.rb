# frozen_string_literal: true

# A check payout remembers who it was approved to be paid to, and the admin
# writes the check to that payee. Organizers can't edit payee details while
# a check payout is pending or processing; if older data still differs, the
# admin records "paid" only after confirming the check went to the approved
# payee (kept in the audit evidence). Existing payouts keep an empty snapshot.
class AddPayeeSnapshotToPayouts < ActiveRecord::Migration[8.1]
  def change
    add_column :payouts, :payee_snapshot, :jsonb, default: {}, null: false
    add_column :payouts, :payee_approval_digest, :string
    add_check_constraint :payouts, "jsonb_typeof(payee_snapshot) = 'object'", name: "payouts_payee_snapshot_object"
  end
end
