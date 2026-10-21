# frozen_string_literal: true

# Admins invite HåfaPass staff (admin or support) by email. The role is
# applied only after the invitee signs in with that verified address.
class CreatePlatformInvitations < ActiveRecord::Migration[8.1]
  def change
    create_table :platform_invitations do |t|
      t.string :email, null: false
      t.integer :role, null: false
      t.integer :status, null: false, default: 0
      t.integer :invitation_version, null: false, default: 1
      t.datetime :invited_at, null: false
      t.datetime :expires_at, null: false
      t.datetime :accepted_at
      t.datetime :revoked_at
      t.references :invited_by_user, null: false, foreign_key: { to_table: :users }
      t.references :accepted_by_user, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :platform_invitations, "lower(email)", unique: true, where: "status = 0",
      name: "idx_platform_invitations_unique_pending_email"
    add_check_constraint :platform_invitations, "role IN (2, 3)", name: "platform_invitations_staff_role"
    add_check_constraint :platform_invitations, "status IN (0, 1, 2)", name: "platform_invitations_status_valid"
    add_check_constraint :platform_invitations, "invitation_version > 0", name: "platform_invitations_version_positive"
    add_check_constraint :platform_invitations, "status <> 1 OR (accepted_at IS NOT NULL AND accepted_by_user_id IS NOT NULL)",
      name: "platform_invitations_acceptance_recorded"
  end
end
