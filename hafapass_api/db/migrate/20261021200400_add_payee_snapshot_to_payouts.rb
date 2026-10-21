# frozen_string_literal: true

# A check payout remembers who it was approved to be paid to. If the payee
# changes while the payout is in flight, the admin sees the approved payee
# and cannot record the check as paid until the new details are approved.
# Existing payouts keep an empty snapshot and are unaffected.
class AddPayeeSnapshotToPayouts < ActiveRecord::Migration[8.1]
  def change
    add_column :payouts, :payee_snapshot, :jsonb, default: {}, null: false
    add_column :payouts, :payee_approval_digest, :string
    add_check_constraint :payouts, "jsonb_typeof(payee_snapshot) = 'object'", name: "payouts_payee_snapshot_object"
  end
end
