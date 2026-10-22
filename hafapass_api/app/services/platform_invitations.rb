# frozen_string_literal: true

require "digest"

# Admin and Support invitations. An invitation is pending until the invitee
# signs in with the invited email *verified by Clerk*; editable contact
# details are never treated as proof. Accepting never lowers a role.
class PlatformInvitations
  class InvitationError < StandardError; end

  NAMESPACE = "platform_invitation"

  class << self
    def invite!(email:, role:, actor:, request: nil)
      email = email.to_s.strip.downcase
      role = role.to_s
      raise InvitationError, "Enter a valid email address" unless email.match?(URI::MailTo::EMAIL_REGEXP)
      raise InvitationError, "Choose Admin or Support" unless PlatformInvitation.roles.key?(role)

      existing_user = User.where("LOWER(email) = ?", email).first
      if existing_user && User::STAFF_ROLE_RANK.fetch(existing_user.role) >= User::STAFF_ROLE_RANK.fetch(role)
        raise InvitationError, "#{email} already has #{OrganizationRoles.platform_label(existing_user.role)} access"
      end

      invitation = PlatformInvitation.transaction do
        record = PlatformInvitation.status_pending.where("LOWER(email) = ?", email).lock.first
        record ||= PlatformInvitation.new(email: email, invitation_version: 0)
        record.assign_attributes(role: role, invited_by_user: actor, invited_at: Time.current,
          expires_at: PlatformInvitation::LIFETIME.from_now, invitation_version: record.invitation_version + 1)
        record.save!
        record
      end
      AuditLogger.record!(action: "platform.invitation_created", auditable: invitation, actor: actor,
        after_data: invitation_snapshot(invitation), request: request)
      EmailService.send_platform_invitation_async(invitation, requested_by: actor)
      invitation
    rescue ActiveRecord::RecordInvalid => e
      raise InvitationError, e.record.errors.full_messages.to_sentence
    rescue ActiveRecord::RecordNotUnique
      raise InvitationError, "An invitation for that email is already pending"
    end

    def resend!(invitation:, actor:, request: nil)
      invitation.with_lock do
        raise InvitationError, "Only pending or expired invitations can be resent" unless invitation.status_pending?

        # The resending admin becomes the inviter, so the link works even if
        # the original inviter has since lost admin access.
        invitation.update!(invited_at: Time.current, expires_at: PlatformInvitation::LIFETIME.from_now,
          invitation_version: invitation.invitation_version + 1, invited_by_user: actor)
      end
      AuditLogger.record!(action: "platform.invitation_resent", auditable: invitation, actor: actor,
        after_data: invitation_snapshot(invitation), request: request)
      EmailService.send_platform_invitation_async(invitation, requested_by: actor)
      invitation
    end

    def revoke!(invitation:, actor:, request: nil)
      invitation.with_lock do
        raise InvitationError, "Only pending invitations can be revoked" unless invitation.status_pending?

        invitation.update!(status: :revoked, revoked_at: Time.current,
          invitation_version: invitation.invitation_version + 1)
      end
      AuditLogger.record!(action: "platform.invitation_revoked", auditable: invitation, actor: actor,
        after_data: invitation_snapshot(invitation), request: request)
      invitation
    end

    def token_for(invitation)
      SignedCredential.issue(namespace: NAMESPACE,
        payload: { invitation_id: invitation.id, version: invitation.invitation_version },
        expires_at: invitation.expires_at)
    end

    def accept_url(invitation)
      "#{PublicSiteUrl.frontend}/platform-invitations/accept?token=#{ERB::Util.url_encode(token_for(invitation))}"
    end

    def accept!(token:, user:, request: nil)
      payload = SignedCredential.verify(namespace: NAMESPACE, token: token)
      invitation = payload && PlatformInvitation.find_by(id: payload["invitation_id"])
      raise InvitationError, "Invitation is invalid or expired" unless invitation
      # Ask Clerk before taking the row lock; the checks below repeat under it.
      unless ClerkIdentity.email_matches?(user: user, email: invitation.email)
        raise InvitationError, "Sign in with the verified email address that received this invitation and try again."
      end

      invitation.with_lock do
        unless invitation.display_status == "pending" && invitation.invitation_version == payload["version"].to_i
          raise InvitationError, "Invitation is invalid or expired"
        end
        unless inviter_still_admin?(invitation)
          raise InvitationError, "This invitation is no longer valid. Ask a HåfaPass admin to send a new one."
        end

        apply!(invitation, user, request: request)
      end
      invitation
    end

    # Signing in with a verified invited email applies the role even when the
    # person never clicks the link. Only checks Clerk when an open invitation
    # names the account's contact email, so ordinary sign-ins stay cheap.
    #
    # A contact email that matches but is not verified would otherwise cost a
    # Clerk lookup on every page load, so a miss is remembered briefly for
    # that exact set of invitations.
    MISS_CACHE_TTL = 10.minutes

    def apply_pending_for!(user, request: nil)
      return [] if user.email.blank?

      candidates = PlatformInvitation.unexpired_pending.includes(:invited_by_user)
        .where("LOWER(email) = ?", user.email.to_s.strip.downcase).order(:id).to_a
      candidates.select! { |invitation| inviter_still_admin?(invitation) }
      return [] if candidates.empty?

      miss_key = "platform-invitation-miss/#{user.id}/" +
        Digest::SHA256.hexdigest(candidates.map { |item| [item.id, item.invitation_version] }.to_json)
      return [] if Rails.cache.read(miss_key)

      applied = candidates.filter_map do |invitation|
        next unless ClerkIdentity.email_matches?(user: user, email: invitation.email)

        invitation.with_lock do
          next unless invitation.display_status == "pending" && inviter_still_admin?(invitation)

          apply!(invitation, user, request: request)
          invitation
        end
      end
      Rails.cache.write(miss_key, true, expires_in: MISS_CACHE_TTL) if applied.empty?
      applied
    end

    # Pending invitations stop working when the admin who sent them loses
    # admin access; they are revoked so the list says so.
    def revoke_sent_by!(user, actor:, request: nil)
      PlatformInvitation.status_pending.where(invited_by_user: user).find_each do |invitation|
        revoke!(invitation: invitation, actor: actor, request: request)
      end
    end

    def invitation_json(invitation)
      delivery = invitation.message_deliveries.order(:id).last
      {
        id: invitation.id,
        email: invitation.email,
        role: invitation.role,
        status: invitation.display_status,
        invited_at: invitation.invited_at,
        expires_at: invitation.expires_at,
        accepted_at: invitation.accepted_at,
        revoked_at: invitation.revoked_at,
        invited_by: invitation.invited_by_user&.email,
        accepted_by: invitation.accepted_by_user&.email,
        email_delivery: delivery_json(delivery)
      }
    end

    def delivery_json(delivery)
      return nil unless delivery

      { status: delivery.status, provider: delivery.provider, updated_at: delivery.updated_at }
    end

    private

    def inviter_still_admin?(invitation)
      invitation.invited_by_user&.reload&.admin?
    end

    def apply!(invitation, user, request:)
      previous_role = user.role
      if User::STAFF_ROLE_RANK.fetch(invitation.role) > User::STAFF_ROLE_RANK.fetch(user.role)
        user.update!(role: invitation.role)
      end
      invitation.update!(status: :accepted, accepted_at: Time.current, accepted_by_user: user,
        invitation_version: invitation.invitation_version + 1)
      AuditLogger.record!(action: "platform.invitation_accepted", auditable: invitation, actor: user,
        before_data: { role: previous_role }, after_data: { role: user.role }, request: request)
      return if previous_role == user.role

      AuditLogger.record!(action: "user.role_updated", auditable: user, actor: user,
        before_data: { role: previous_role }, after_data: { role: user.role },
        metadata: { platform_invitation_id: invitation.id, invited_by_user_id: invitation.invited_by_user_id },
        request: request)
    end

    def invitation_snapshot(invitation)
      invitation.attributes.slice("email", "role", "status", "invitation_version", "expires_at")
    end
  end
end
