# Adds the processing-fee bearer and payout schedule settings, and moves the
# column defaults to the all-in buyer fee (5% + $1.00 per paid ticket).
#
# This migration deliberately does not change the existing singleton row's fee
# values: code from the previous release may still be serving checkouts while
# it runs, and it would apply a new fee without snapshotting the bearer. After
# the new release is live, run `bin/rails hafapass:adopt_launch_fee_terms`,
# which moves an untouched 3% + 50¢ row to the new terms and audits the change.
# Rolling back restores the column defaults only; row values are never
# rewritten because they may have been chosen by an admin.
class AdoptAllInBuyerFeeDefaults < ActiveRecord::Migration[8.1]
  def up
    add_column :site_settings, :processing_fee_bearer, :string, null: false, default: "platform"
    add_column :site_settings, :payout_schedule_text, :string, null: false,
      default: "within 3 business days after your event"
    add_check_constraint :site_settings, "processing_fee_bearer IN ('platform', 'organizer')",
      name: "site_settings_processing_fee_bearer_valid"
    change_column_default :site_settings, :service_fee_percent, from: 3.0, to: 5.0
    change_column_default :site_settings, :service_fee_flat_cents, from: 50, to: 100
  end

  def down
    change_column_default :site_settings, :service_fee_flat_cents, from: 100, to: 50
    change_column_default :site_settings, :service_fee_percent, from: 5.0, to: 3.0
    remove_check_constraint :site_settings, name: "site_settings_processing_fee_bearer_valid"
    remove_column :site_settings, :payout_schedule_text
    remove_column :site_settings, :processing_fee_bearer
  end
end
