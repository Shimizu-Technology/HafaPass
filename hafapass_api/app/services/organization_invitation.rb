# frozen_string_literal: true

class OrganizationInvitation
  LIFETIME = 7.days

  class InvitationError < StandardError; end

  class << self
    def issue!(membership)
      membership.with_lock do
        membership.update!(invited_at: Time.current, expires_at: LIFETIME.from_now)
      end
      SignedCredential.issue(
        namespace: "organization_invitation",
        payload: { membership_id: membership.id, version: membership.invitation_version },
        expires_at: membership.expires_at
      )
    end

    def accept!(token:, user:)
      payload = SignedCredential.verify(namespace: "organization_invitation", token: token)
      raise InvitationError, "Invitation is invalid or expired" unless payload

      membership = OrganizationMembership.find_by(id: payload["membership_id"] || payload[:membership_id])
      version = (payload["version"] || payload[:version]).to_i
      raise InvitationError, "Invitation is invalid or expired" unless membership

      membership.with_lock do
        unless membership.status_invited? && membership.invitation_version == version &&
            membership.expires_at&.future? && email_matches?(membership, user)
          raise InvitationError, "Invitation is invalid or expired"
        end
        if membership.organization.organization_memberships.effective.exists?(user: user)
          raise InvitationError, "You are already a member of this organization"
        end

        membership.update!(
          user: user,
          status: :active,
          accepted_at: Time.current,
          invitation_version: membership.invitation_version + 1
        )
      end
      membership
    end

    def revoke!(membership)
      membership.update!(status: :revoked, invitation_version: membership.invitation_version + 1)
    end

    private

    def email_matches?(membership, user)
      membership.invited_email.to_s.casecmp?(user.email.to_s)
    end
  end
end
