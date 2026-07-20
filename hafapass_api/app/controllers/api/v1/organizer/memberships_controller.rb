# frozen_string_literal: true

class Api::V1::Organizer::MembershipsController < Api::V1::Organizer::BaseController
  before_action :require_member_management
  before_action :set_membership, only: [:update, :destroy]

  def index
    render json: current_organization.organization_memberships.includes(:user).order(:id).map { |membership| membership_json(membership) }
  end

  def create
    email = params[:email].to_s.strip.downcase
    role = params[:role].to_s
    unless OrganizationMembership.roles.except("owner").key?(role) && email.match?(URI::MailTo::EMAIL_REGEXP)
      return render json: { error: "A valid email and non-owner role are required" }, status: :unprocessable_entity
    end
    if current_organization.organization_memberships.effective.joins(:user).where("LOWER(users.email) = ?", email).exists?
      return render json: { error: "That person is already a member" }, status: :unprocessable_entity
    end

    known_user = User.where("LOWER(email) = ?", email).first
    membership = current_organization.organization_memberships.find_by(user: known_user) if known_user
    membership ||= current_organization.organization_memberships.where("LOWER(invited_email) = ?", email).first
    membership ||= current_organization.organization_memberships.build
    membership.assign_attributes(
      invited_email: email,
      invited_by_user: current_user,
      role: role,
      status: :invited,
      accepted_at: nil,
      invitation_version: membership.new_record? ? 1 : membership.invitation_version + 1
    )
    membership.save!
    token = OrganizationInvitation.issue!(membership)
    AuditLogger.record!(
      action: "organization.invitation_created",
      auditable: membership,
      actor: current_user,
      organization: current_organization,
      after_data: { invited_email: email, role: role, expires_at: membership.expires_at },
      request: request
    )
    render json: membership_json(membership).merge(invitation_token: token), status: :created
  rescue ActiveRecord::RecordNotUnique
    render json: { error: "An active invitation already exists for that email" }, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  def update
    role = params[:role].to_s
    unless OrganizationMembership.roles.except("owner").key?(role) && !@membership.owner?
      return render json: { error: "Ownership changes require the dedicated ownership-transfer process" },
        status: :unprocessable_entity
    end

    before_data = membership_json(@membership)
    @membership.update!(role: role, expires_at: params[:expires_at])
    AuditLogger.record!(
      action: "organization.membership_updated",
      auditable: @membership,
      actor: current_user,
      organization: current_organization,
      before_data: before_data,
      after_data: membership_json(@membership),
      request: request
    )
    render json: membership_json(@membership)
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  def destroy
    return render json: { error: "The owner membership cannot be revoked here" }, status: :unprocessable_entity if @membership.owner?

    OrganizationInvitation.revoke!(@membership)
    AuditLogger.record!(
      action: "organization.membership_revoked",
      auditable: @membership,
      actor: current_user,
      organization: current_organization,
      request: request
    )
    head :no_content
  end

  private

  def require_member_management
    authorize_organization!(:manage_members)
  end

  def set_membership
    @membership = current_organization.organization_memberships.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Membership not found" }, status: :not_found
  end

  def membership_json(membership)
    {
      id: membership.id,
      user_id: membership.user_id,
      email: membership.user&.email || membership.invited_email,
      name: membership.user ? [membership.user.first_name, membership.user.last_name].compact.join(" ").presence : nil,
      role: membership.role,
      status: membership.status,
      accepted_at: membership.accepted_at,
      expires_at: membership.expires_at,
      invited_at: membership.invited_at
    }
  end
end
