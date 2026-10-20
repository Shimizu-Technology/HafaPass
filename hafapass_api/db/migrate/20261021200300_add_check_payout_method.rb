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

  def down
    change_column_null :organizer_profiles, :user_id, false
    remove_check_constraint :connected_accounts, name: "connected_accounts_payout_details_object"
    remove_check_constraint :connected_accounts, name: "connected_accounts_provider_valid"
    add_check_constraint :connected_accounts, "provider IN ('paypal', 'manual', 'stripe', 'legacy_manual')",
      name: "connected_accounts_provider_valid"
    remove_column :connected_accounts, :payout_details
  end
end
