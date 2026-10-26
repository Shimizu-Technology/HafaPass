# frozen_string_literal: true

# Email-bound organization invitations. The link lifetime lives in
# invitation_expires_at; accepting an invitation never sets an access expiry,
# so an accepted teammate keeps access until an owner changes or revokes it.
class OrganizationInvitation
  LIFETIME = 7.days

  class InvitationError < StandardError; end

  class << self
    # Starts (or restarts) the link lifetime and returns the secure token.
    def issue!(membership)
      membership.with_lock do
        membership.update!(invited_at: Time.current, invitation_expires_at: LIFETIME.from_now)
      end
      token_for(membership)
    end

    # The token for the membership's current version and lifetime. Rotating
    # the version (resend, revoke, accept) invalidates every earlier link.
    def token_for(membership)
      SignedCredential.issue(
        namespace: "organization_invitation",
        payload: { membership_id: membership.id, version: membership.invitation_version },
        expires_at: membership.invitation_expires_at
      )
    end

    def accept_url(membership)
      "#{PublicSiteUrl.frontend}/organization-invitations/accept?token=#{ERB::Util.url_encode(token_for(membership))}"
    end

    def accept!(token:, user:)
      payload = SignedCredential.verify(namespace: "organization_invitation", token: token)
      raise InvitationError, "Invitation is invalid or expired" unless payload

      membership = OrganizationMembership.find_by(id: payload["membership_id"] || payload[:membership_id])
      version = (payload["version"] || payload[:version]).to_i
      raise InvitationError, "Invitation is invalid or expired" unless membership

      # Acceptance already has its user: own ACTOR before ORG, including
      # callers with a wider audit transaction, then update the derived label
      # while that same user lock is still owned.
      user.with_lock("FOR NO KEY UPDATE") do
        membership.organization.with_lock do
          membership.lock!
          unless membership.status_invited? && membership.invitation_version == version && membership.invitation_open?
            raise InvitationError, "Invitation is invalid or expired"
          end
          unless email_matches?(membership, user)
            raise InvitationError, "We could not verify the recipient email. Sign in with the verified email address that received this invitation and try again."
          end
          if membership.organization.organization_memberships.effective.exists?(user: user)
            raise InvitationError, "You are already a member of this organization"
          end

          if membership.owner? && membership.organization.organization_memberships.where(role: :owner)
              .where.not(id: membership.id).any?(&:effective?)
            raise InvitationError, "This organization already has an owner. Ask HåfaPass to send a new invitation."
          end

          earlier = membership.organization.organization_memberships.where(user: user).where.not(id: membership.id).first
          accepted = earlier ? rejoin!(earlier, membership) : membership
          accepted.update!(
            user: user,
            status: :active,
            accepted_at: Time.current,
            expires_at: nil,
            invitation_version: accepted.invitation_version + 1
          )
          apply_pending_event_assignments!(accepted)
          adopt_organizer_profile!(accepted) if accepted.owner?
          membership = accepted
        end
        user.sync_member_label!
      end
      membership
    end

    def revoke!(membership)
      membership.update!(status: :revoked, invitation_version: membership.invitation_version + 1,
        pending_event_assignments: [])
      refresh_member_label_after_commit(membership.user)
    end

    private

    # The label is derived, never authorization. Revocation and its
    # audits stay atomic under ORG; updating USER there would invert the
    # actor -> ORG order used by scanning, staff mutations and invite quotas.
    # Wait for the outermost commit, then reload/lock USER before deriving the
    # label so a delayed callback observes any later committed membership.
    def refresh_member_label_after_commit(user)
      return unless user

      ActiveRecord.after_all_transactions_commit do
        user.with_lock("FOR NO KEY UPDATE") { user.sync_member_label! }
      end
    end

    # Someone removed earlier (or whose access ended) keeps one row per
    # organization: the new invitation's role and events move onto it and the
    # invitation row is closed, so history stays attached to one record.
    def rejoin!(earlier, invitation)
      earlier.lock!
      incoming = invitation.attributes.slice("role", "invited_email", "invited_by_user_id", "invited_at",
        "pending_event_assignments")
      # Close the incoming invitation first so its email is free for the
      # earlier row under the one-open-invitation-per-email index.
      invitation.update!(status: :revoked, invitation_version: invitation.invitation_version + 1,
        pending_event_assignments: [])
      earlier.update!(incoming)
      earlier
    rescue ActiveRecord::RecordNotUnique
      raise InvitationError, "We couldn't attach this invitation to your earlier membership. Ask the organization owner to send a new one."
    end

    def email_matches?(membership, user)
      ClerkIdentity.email_matches?(user: user, email: membership.invited_email)
    end

    # Staff invited from an event's Team page get that event's access as
    # soon as they accept, so nobody has to come back and assign them.
    def apply_pending_event_assignments!(membership)
      entries = Array(membership.pending_event_assignments)
      return if entries.empty?

      events = membership.organization.events.where(id: entries.map { |entry| entry["event_id"] }).index_by(&:id)
      entries.each do |entry|
        event = events[entry["event_id"].to_i]
        next unless event

        assignment = event.event_staff_assignments.find_or_initialize_by(user: membership.user, role: entry["role"])
        # A reused old assignment may carry a past end date; event invites
        # grant open-ended access, like assigning an existing member.
        assignment.update!(organization: membership.organization, status: :active, expires_at: nil,
          assigned_by_user_id: entry["assigned_by_user_id"] || membership.invited_by_user_id)
      end
      membership.update!(pending_event_assignments: [])
    end

    # An organization created by an admin has no profile owner until the
    # invited owner accepts.
    def adopt_organizer_profile!(membership)
      profile = membership.organization.organizer_profile
      return unless profile && profile.user_id.nil?
      return if OrganizerProfile.exists?(user_id: membership.user_id)

      profile.update!(user: membership.user)
    end
  end
end
