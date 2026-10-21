# frozen_string_literal: true

class AddTaxSnapshotToPayouts < ActiveRecord::Migration[8.0]
  def change
    add_column :payouts, :tax_information_snapshot, :jsonb, null: false, default: {}
    add_column :payouts, :tax_information_tin, :text
    add_column :payouts, :tax_approval_digest, :string
    add_check_constraint :payouts, "jsonb_typeof(tax_information_snapshot) = 'object'", name: "payouts_tax_snapshot_object"
  end
end
