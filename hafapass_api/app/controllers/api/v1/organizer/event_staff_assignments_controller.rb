# frozen_string_literal: true

class Api::V1::Organizer::EventStaffAssignmentsController < Api::V1::Organizer::BaseController
  before_action :set_event
  before_action :require_staff_management
  before_action :set_assignment, only: [:update, :destroy]
  before_action :set_staff_invitation, only: [:resend_invitation, :revoke_invitation]

  around_action :serialize_staff_mutation, only: [:create, :update, :destroy, :resend_invitation, :revoke_invitation]

  def index
    candidates = current_organization.organization_memberships.effective.includes(:user).order(:id).filter_map do |membership|
      next unless membership.user

      {
        user_id: membership.user_id,
        email: membership.user.email,
        name: [membership.user.first_name, membership.user.last_name].compact.join(" ").presence,
        organization_role: membership.role
      }
    end
    render json: {
      assignments: @event.event_staff_assignments.includes(:user).order(:id).map { |assignment| assignment_json(assignment) },
      candidates: candidates,
      pending_invitations: pending_invitations.map { |membership| staff_invitation_json(membership) }
    }
  end

  def create
    role = validated_role
    return unless role
    return invite_by_email(role) if params[:email].present?

    membership = current_organization.organization_memberships.effective.find_by!(user_id: params[:user_id])
    assignment = @event.event_staff_assignments.find_or_initialize_by(user: membership.user, role: role)
    assignment.assign_attributes(
      organization: current_organization,
      assigned_by_user: current_user,
      status: :active,
      expires_at: params[:expires_at]
    )
    assignment.save!
    audit_assignment!("event_staff.assigned", assignment)
    render json: assignment_json(assignment), status: :created
  rescue ActiveRecord::RecordNotFound
    render json: { error: "An active organization member is required" }, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  def update
    role = validated_role
    return unless role

    @assignment.update!(role: role, expires_at: params[:expires_at], status: :active)
    audit_assignment!("event_staff.updated", @assignment)
    render json: assignment_json(@assignment)
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  def destroy
    @assignment.update!(status: :revoked)
    audit_assignment!("event_staff.revoked", @assignment)
    head :no_content
  end

  def resend_invitation
    unless OrganizationRoles::EVENT_STAFF_INVITE_ROLES.include?(@staff_invitation.role) ||
        OrganizationAuthorization.allowed?(user: current_user, organization: current_organization, permission: :manage_members)
      return render json: { error: "Only the organization owner can resend this invitation" }, status: :forbidden
    end

    token = OrganizationTeam.resend!(membership: @staff_invitation, actor: current_user, request: request, event: @event)
    render json: staff_invitation_json(@staff_invitation.reload).merge(OrganizationTeam.link_json(token))
  rescue OrganizationTeam::TeamError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # Takes this event off a pending invitation. An invitation that existed only
  # for event work (box office or scanner with no other events) is revoked.
  def revoke_invitation
    membership = @staff_invitation
    membership.with_lock do
      remaining = Array(membership.pending_event_assignments).reject { |entry| entry["event_id"].to_i == @event.id }
      if remaining.empty? && OrganizationRoles::EVENT_STAFF_INVITE_ROLES.include?(membership.role)
        OrganizationInvitation.revoke!(membership)
      else
        membership.update!(pending_event_assignments: remaining)
      end
    end
    AuditLogger.record!(action: "event_staff.invitation_revoked", auditable: membership, actor: current_user,
      organization: current_organization, after_data: { event_id: @event.id, status: membership.status }, request: request)
    head :no_content
  end

  private

  # Event manager assignments can grant marketing access. Share the team
  # lock with campaign dispatch and recheck authority after any lock wait.
  def serialize_staff_mutation
    current_user.with_lock("FOR NO KEY UPDATE") do
      current_organization.with_lock do
        yield if authorize_organization!(:manage_staff, event: @event)
      end
    end
  end

  # One step for the person running the event: invite by email with Box
  # office or Door scanner access to this event. People already on the team
  # are assigned immediately; everyone else gets an emailed invitation and
  # this event's access the moment they accept.
  def invite_by_email(role)
    unless OrganizationRoles::EVENT_STAFF_INVITE_ROLES.include?(role)
      return render json: { error: "Invite event staff as Box office or Door scanner" }, status: :unprocessable_entity
    end

    email = params[:email].to_s.strip.downcase
    existing = OrganizationTeam.effective_member_for(current_organization, email)
    if existing
      assignment = @event.event_staff_assignments.find_or_initialize_by(user: existing.user, role: role)
      assignment.assign_attributes(organization: current_organization, assigned_by_user: current_user, status: :active,
        expires_at: nil)
      assignment.save!
      audit_assignment!("event_staff.assigned", assignment)
      return render json: { assignment: assignment_json(assignment) }, status: :created
    end

    membership, token = OrganizationTeam.invite!(organization: current_organization, email: email, role: role,
      actor: current_user, request: request, event_assignment: { event: @event, role: role })
    render json: { invitation: staff_invitation_json(membership).merge(OrganizationTeam.link_json(token)) }, status: :created
  rescue OrganizationTeam::TeamError => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  def pending_invitations
    current_organization.organization_memberships.status_invited
      .where("pending_event_assignments @> ?", [{ event_id: @event.id }].to_json).order(:id)
  end

  def set_staff_invitation
    return unless @event

    @staff_invitation = pending_invitations.find_by(id: params[:membership_id])
    render json: { error: "Invitation not found for this event" }, status: :not_found unless @staff_invitation
  end

  def staff_invitation_json(membership)
    entry = Array(membership.pending_event_assignments).find { |item| item["event_id"].to_i == @event.id }
    OrganizationTeam.membership_json(membership).slice(:id, :email, :invitation_status, :invitation_expires_at,
      :email_delivery).merge(membership_id: membership.id, role: entry&.fetch("role", nil) || membership.role)
  end

  def set_event
    @event = find_organization_event(params[:event_id])
  end

  def require_staff_management
    authorize_organization!(:manage_staff, event: @event) if @event
  end

  def set_assignment
    @assignment = @event.event_staff_assignments.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Staff assignment not found" }, status: :not_found
  end

  def validated_role
    role = params[:role].to_s
    return role if EventStaffAssignment.roles.key?(role)

    render json: { error: "role must be one of: #{EventStaffAssignment.roles.keys.join(", ")}" },
      status: :unprocessable_entity
    nil
  end

  def audit_assignment!(action, assignment)
    AuditLogger.record!(
      action: action,
      auditable: assignment,
      actor: current_user,
      organization: current_organization,
      after_data: assignment_json(assignment),
      request: request
    )
  end

  def assignment_json(assignment)
    {
      id: assignment.id,
      event_id: assignment.event_id,
      user_id: assignment.user_id,
      email: assignment.user.email,
      role: assignment.role,
      status: assignment.status,
      expires_at: assignment.expires_at
    }
  end
end
