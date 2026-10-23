# frozen_string_literal: true

class OrganizationInvitationQuota
  ACTOR_HOURLY_LIMIT = 30
  ORGANIZATION_HOURLY_LIMIT = 100
  RECIPIENT_COOLDOWN = 1.minute

  def self.within!(organization:, actor:, email:)
    recipient = email.to_s.strip.downcase
    # Always actor then organization, including across organizations. This
    # serializes per-person and per-team budgets on every app worker.
    actor.with_lock("FOR NO KEY UPDATE") do
      organization.with_lock do
        recent = OrganizationInvitationDispatch.where(created_at: 1.hour.ago..)
        if recent.where(actor_user: actor).count >= ACTOR_HOURLY_LIMIT
          raise OrganizationTeam::TeamError, "You've sent 30 invitations in the past hour. Try again later or copy an existing invitation link."
        end
        if recent.where(organization: organization).count >= ORGANIZATION_HOURLY_LIMIT
          raise OrganizationTeam::TeamError, "This team has sent 100 invitations in the past hour. Try again later or copy an existing invitation link."
        end
        if recent.where(organization: organization, recipient: recipient).where(created_at: RECIPIENT_COOLDOWN.ago..).exists?
          raise OrganizationTeam::TeamError, "An invitation was just sent to this email. Wait a minute before resending, or copy the invitation link."
        end
        result = yield
        OrganizationInvitationDispatch.create!(organization: organization, actor_user: actor, recipient: recipient)
        result
      end
    end
  end
end
