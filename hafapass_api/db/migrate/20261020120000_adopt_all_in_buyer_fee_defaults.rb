# Adopt the all-in buyer fee (5% + $1.00 per paid ticket, card processing
# included and borne by the platform) as the platform default.
#
# Only a singleton row still holding the untouched 3% + 50¢ pair is moved to
# the new pair; an admin-chosen fee is left alone. Rolling back restores the
# column defaults but never rewrites row values: a row reading 5% + $1.00 may
# have been chosen by an admin. Existing orders are unaffected either way —
# every order snapshots its own fee and processing-fee bearer at creation.
class AdoptAllInBuyerFeeDefaults < ActiveRecord::Migration[8.1]
  def up
    add_column :site_settings, :processing_fee_bearer, :string, null: false, default: "platform"
    add_column :site_settings, :payout_schedule_text, :string, null: false,
      default: "within 3 business days after your event"
    add_check_constraint :site_settings, "processing_fee_bearer IN ('platform', 'organizer')",
      name: "site_settings_processing_fee_bearer_valid"
    change_column_default :site_settings, :service_fee_percent, from: 3.0, to: 5.0
    change_column_default :site_settings, :service_fee_flat_cents, from: 50, to: 100
    execute <<~SQL.squish
      UPDATE site_settings
      SET service_fee_percent = 5.0, service_fee_flat_cents = 100, updated_at = CURRENT_TIMESTAMP
      WHERE service_fee_percent = 3.0 AND service_fee_flat_cents = 50
    SQL
  end

  def down
    change_column_default :site_settings, :service_fee_flat_cents, from: 100, to: 50
    change_column_default :site_settings, :service_fee_percent, from: 5.0, to: 3.0
    remove_check_constraint :site_settings, name: "site_settings_processing_fee_bearer_valid"
    remove_column :site_settings, :payout_schedule_text
    remove_column :site_settings, :processing_fee_bearer
  end
end
