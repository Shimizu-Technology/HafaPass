# frozen_string_literal: true

# Organizers are paid by check from Shimizu Technology's business account.
# "check" becomes a first-class payout method whose payee details live on the
# connected account. Existing accounts keep empty details, so their readiness
# digests (and any approvals bound to them) are unchanged.
#
# Admin-created organizations have no owner account until the invitee signs
# in, so the organizer profile's creator becomes optional.
class AddCheckPayoutMethod < ActiveRecord::Migration[8.1]
  def up
    add_column :connected_accounts, :payout_details, :jsonb, default: {}, null: false
    remove_check_constraint :connected_accounts, name: "connected_accounts_provider_valid"
    add_check_constraint :connected_accounts, "provider IN ('paypal', 'manual', 'stripe', 'legacy_manual', 'check')",
      name: "connected_accounts_provider_valid"
    add_check_constraint :connected_accounts, "jsonb_typeof(payout_details) = 'object'",
      name: "connected_accounts_payout_details_object"
    change_column_null :organizer_profiles, :user_id, true
  end

  # Rolling back would drop organizers' check payee details and fail on
  # admin-created organizations whose owner has not accepted yet.
  def down
    if select_value("SELECT 1 FROM connected_accounts WHERE provider = 'check' LIMIT 1") ||
        select_value("SELECT 1 FROM organizer_profiles WHERE user_id IS NULL LIMIT 1")
      raise ActiveRecord::IrreversibleMigration,
        "Check payout accounts or owner-less organizer profiles exist; migrate them before rolling back"
    end

    change_column_null :organizer_profiles, :user_id, false
    remove_check_constraint :connected_accounts, name: "connected_accounts_payout_details_object"
    remove_check_constraint :connected_accounts, name: "connected_accounts_provider_valid"
    add_check_constraint :connected_accounts, "provider IN ('paypal', 'manual', 'stripe', 'legacy_manual')",
      name: "connected_accounts_provider_valid"
    remove_column :connected_accounts, :payout_details
  end
end
