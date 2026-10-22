# frozen_string_literal: true

# An organization invitation's 7-day link lifetime was stored in the same
# column as membership access expiry, and accepting never cleared it, so an
# accepted teammate silently lost access on the 8th day. Invitation lifetime
# now has its own column; expires_at means only "access ends at", set
# deliberately by an owner.
#
# Data repair: open invitations move their link expiry to the new column.
# Accepted memberships whose expires_at is exactly the stale invite lifetime
# (invited_at + 7 days, to the minute) get it cleared, restoring access that
# the bug removed. Any other expires_at was chosen by an owner and is kept.
class SeparateInvitationExpiryFromMembershipExpiry < ActiveRecord::Migration[8.1]
  def up
    add_column :organization_memberships, :invitation_expires_at, :datetime
    add_column :organization_memberships, :pending_event_assignments, :jsonb, default: [], null: false

    execute <<~SQL.squish
      UPDATE organization_memberships
      SET invitation_expires_at = expires_at, expires_at = NULL
      WHERE accepted_at IS NULL AND expires_at IS NOT NULL
    SQL
    execute <<~SQL.squish
      UPDATE organization_memberships
      SET expires_at = NULL
      WHERE accepted_at IS NOT NULL AND invited_at IS NOT NULL AND expires_at IS NOT NULL
        AND abs(extract(epoch FROM (expires_at - (invited_at + interval '7 days')))) < 60
    SQL
    add_check_constraint :organization_memberships, "jsonb_typeof(pending_event_assignments) = 'array'",
      name: "organization_memberships_pending_event_assignments_array"
  end

  def down
    execute <<~SQL.squish
      UPDATE organization_memberships
      SET expires_at = invitation_expires_at
      WHERE accepted_at IS NULL AND invitation_expires_at IS NOT NULL
    SQL
    remove_check_constraint :organization_memberships, name: "organization_memberships_pending_event_assignments_array"
    remove_column :organization_memberships, :pending_event_assignments
    remove_column :organization_memberships, :invitation_expires_at
  end
end
