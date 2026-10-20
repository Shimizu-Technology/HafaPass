# frozen_string_literal: true

# Team changes for one organization, shared by the organizer Settings page,
# the event Team page and the admin organization console. Callers authorize
# first; this service enforces the rules that hold for everyone (owners are
# only created by an admin or an ownership transfer, revoked people lose
# event access, every change is audited).
class OrganizationTeam
  class TeamError < StandardError; end

  INVITABLE_ROLES = (OrganizationMembership.roles.keys - ["owner"]).freeze

  class << self
    # Creates or refreshes an email invitation and emails it (pass
    # deliver: false inside a wider transaction and send after commit).
    # Returns [membership, token]; the token backs the copy-link fallback.
    #
    # event_assignment: { event:, role: } adds that event to what the person
    # can do as soon as they accept. An existing open invitation keeps its
    # organization role and gains the event.
    def invite!(organization:, email:, role:, actor:, request: nil, allow_owner: false, event_assignment: nil,
      deliver: true)
      email = email.to_s.strip.downcase
      role = role.to_s
      allowed_roles = allow_owner ? OrganizationMembership.roles.keys : INVITABLE_ROLES
      raise TeamError, "Enter a valid email address" unless email.match?(URI::MailTo::EMAIL_REGEXP)
      raise TeamError, "Choose one of: #{allowed_roles.map { |item| OrganizationRoles.label(item) }.join(', ')}" unless allowed_roles.include?(role)
      if effective_member_for(organization, email)
        raise TeamError, "That person is already on this team"
      end

      membership = nil
      token = nil
      organization.with_lock do
        membership = find_reusable(organization, email) || organization.organization_memberships.build
        reopening = membership.new_record? || !membership.invitation_open?
        entries = reopening ? [] : Array(membership.pending_event_assignments)
        if event_assignment
          entries = entries.reject { |entry| entry["event_id"].to_i == event_assignment.fetch(:event).id }
          entries << { "event_id" => event_assignment.fetch(:event).id, "role" => event_assignment.fetch(:role).to_s,
                       "assigned_by_user_id" => actor&.id }
        end
        membership.assign_attributes(
          invited_email: email,
          invited_by_user: actor,
          role: event_assignment && !reopening ? membership.role : role,
          status: :invited,
          accepted_at: nil,
          expires_at: nil,
          pending_event_assignments: entries,
          invitation_version: membership.new_record? ? 1 : membership.invitation_version + 1
        )
        membership.save!
        token = OrganizationInvitation.issue!(membership)
      end
      AuditLogger.record!(
        action: "organization.invitation_created",
        auditable: membership,
        actor: actor,
        organization: organization,
        after_data: { invited_email: email, role: membership.role, invitation_expires_at: membership.invitation_expires_at,
                      event_ids: membership.pending_event_ids },
        request: request
      )
      EmailService.send_organization_invitation_async(membership, requested_by: actor) if deliver
      [membership, token]
    rescue ActiveRecord::RecordNotUnique
      raise TeamError, "An invitation for that email is already pending"
    rescue ActiveRecord::RecordInvalid => e
      raise TeamError, e.record.errors.full_messages.to_sentence
    end

    def resend!(membership:, actor:, request: nil)
      token = nil
      membership.with_lock do
        raise TeamError, "Only pending or expired invitations can be resent" unless membership.status_invited?

        membership.update!(invitation_version: membership.invitation_version + 1, invited_by_user: actor)
        token = OrganizationInvitation.issue!(membership)
      end
      AuditLogger.record!(action: "organization.invitation_resent", auditable: membership, actor: actor,
        organization: membership.organization,
        after_data: { invited_email: membership.invited_email, invitation_expires_at: membership.invitation_expires_at },
        request: request)
      EmailService.send_organization_invitation_async(membership, requested_by: actor)
      token
    end

    # The current link for an open invitation, without changing it.
    def invitation_token(membership)
      raise TeamError, "This invitation is no longer open. Resend it to create a new link." unless membership.invitation_open?

      OrganizationInvitation.token_for(membership)
    end

    def revoke!(membership:, actor:, request: nil)
      raise TeamError, "Transfer ownership before removing the owner" if membership.owner? && membership.status_active?
      raise TeamError, "This person's access is already removed" if membership.status_revoked?

      membership.with_lock do
        OrganizationInvitation.revoke!(membership)
        if membership.user_id
          membership.organization.event_staff_assignments.status_active.where(user_id: membership.user_id)
            .update_all(status: EventStaffAssignment.statuses[:revoked], updated_at: Time.current)
        end
      end
      AuditLogger.record!(action: "organization.membership_revoked", auditable: membership, actor: actor,
        organization: membership.organization, request: request)
      membership
    end

    def change_role!(membership:, role:, actor:, request: nil, expires_at: :unchanged)
      role = role.to_s
      if membership.owner? || role == "owner"
        raise TeamError, "Ownership changes use Transfer ownership"
      end
      raise TeamError, "Choose a valid team role" unless INVITABLE_ROLES.include?(role)
      raise TeamError, "This person's access was removed. Invite them again instead." if membership.status_revoked?

      before_data = snapshot(membership)
      attributes = { role: role }
      attributes[:expires_at] = expires_at unless expires_at == :unchanged
      membership.update!(attributes)
      AuditLogger.record!(action: "organization.membership_updated", auditable: membership, actor: actor,
        organization: membership.organization, before_data: before_data, after_data: snapshot(membership),
        request: request)
      membership
    rescue ActiveRecord::RecordInvalid => e
      raise TeamError, e.record.errors.full_messages.to_sentence
    end

    # Hands the Owner role to another active member. The previous owner (or
    # every owner, when an admin performs the transfer for them) becomes a
    # Manager so nobody silently keeps payout control.
    def transfer_ownership!(organization:, to_membership:, actor:, request: nil)
      organization.with_lock do
        to_membership.reload
        unless to_membership.organization_id == organization.id && to_membership.effective? && to_membership.user_id
          raise TeamError, "Choose an active team member who has accepted their invitation"
        end
        raise TeamError, "That person is already the owner" if to_membership.owner?

        owners = organization.organization_memberships.where(role: :owner).where.not(id: to_membership.id)
        actor_owner = owners.find_by(user_id: actor.id)
        raise TeamError, "Only the owner or a HåfaPass admin can transfer ownership" unless actor_owner || actor.admin?

        previous = (actor_owner ? [actor_owner] : owners.to_a)
        before_data = { owners: previous.map { |item| owner_snapshot(item) }, new_owner: owner_snapshot(to_membership) }
        previous.each { |item| item.update!(role: :manager) }
        to_membership.update!(role: :owner, expires_at: nil)
        move_organizer_profile!(organization, previous, to_membership)
        AuditLogger.record!(action: "organization.ownership_transferred", auditable: organization, actor: actor,
          organization: organization, before_data: before_data,
          after_data: { owner: owner_snapshot(to_membership), previous_owners_now: "manager" },
          request: request)
      end
      to_membership
    rescue ActiveRecord::RecordInvalid => e
      raise TeamError, e.record.errors.full_messages.to_sentence
    end

    def membership_json(membership, at: Time.current)
      delivery = membership.message_deliveries.order(:id).last
      events = membership.pending_event_ids.any? ? membership.organization.events.where(id: membership.pending_event_ids).pluck(:id, :title).to_h : {}
      {
        id: membership.id,
        user_id: membership.user_id,
        email: membership.user&.email || membership.invited_email,
        name: membership.user ? [membership.user.first_name, membership.user.last_name].compact.join(" ").presence : nil,
        role: membership.role,
        status: membership.status,
        invitation_status: membership.invitation_status(at: at),
        accepted_at: membership.accepted_at,
        expires_at: membership.expires_at,
        invited_at: membership.invited_at,
        invitation_expires_at: membership.status_invited? ? membership.invitation_expires_at : nil,
        pending_events: Array(membership.pending_event_assignments).filter_map do |entry|
          title = events[entry["event_id"].to_i]
          title && { event_id: entry["event_id"].to_i, title: title, role: entry["role"] }
        end,
        email_delivery: membership.status_invited? ? PlatformInvitations.delivery_json(delivery) : nil
      }
    end

    def effective_member_for(organization, email)
      organization.organization_memberships.effective.joins(:user).where("LOWER(users.email) = ?", email).first
    end

    private

    def find_reusable(organization, email)
      known_user = User.where("LOWER(email) = ?", email).first
      (known_user && organization.organization_memberships.find_by(user: known_user)) ||
        organization.organization_memberships.where("LOWER(invited_email) = ?", email).order(:id).last
    end

    def move_organizer_profile!(organization, previous, to_membership)
      profile = organization.organizer_profile
      return unless profile
      return unless profile.user_id.nil? || previous.any? { |item| item.user_id == profile.user_id }
      return if OrganizerProfile.where.not(id: profile.id).exists?(user_id: to_membership.user_id)

      profile.update!(user_id: to_membership.user_id)
    end

    def snapshot(membership)
      membership.attributes.slice("role", "status", "expires_at")
    end

    def owner_snapshot(membership)
      { membership_id: membership.id, user_id: membership.user_id, email: membership.user&.email }
    end
  end
end
