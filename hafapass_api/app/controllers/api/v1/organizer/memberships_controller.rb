# frozen_string_literal: true

class Api::V1::Organizer::MembershipsController < Api::V1::Organizer::BaseController
  before_action :require_member_management
  before_action :set_membership, only: [:update, :destroy, :resend, :invitation_link, :transfer_ownership]

  def index
    memberships = current_organization.organization_memberships.includes(:user).order(:id)
    render json: memberships.map { |membership| OrganizationTeam.membership_json(membership) }
  end

  def create
    membership, token = OrganizationTeam.invite!(organization: current_organization, email: params[:email],
      role: params[:role], actor: current_user, request: request)
    render json: OrganizationTeam.membership_json(membership).merge(invitation_token: token), status: :created
  rescue OrganizationTeam::TeamError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def update
    expires_at = params.key?(:expires_at) ? params[:expires_at].presence : :unchanged
    OrganizationTeam.change_role!(membership: @membership, role: params[:role], expires_at: expires_at,
      actor: current_user, request: request)
    render json: OrganizationTeam.membership_json(@membership)
  rescue OrganizationTeam::TeamError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def destroy
    OrganizationTeam.revoke!(membership: @membership, actor: current_user, request: request)
    head :no_content
  rescue OrganizationTeam::TeamError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def resend
    token = OrganizationTeam.resend!(membership: @membership, actor: current_user, request: request)
    render json: OrganizationTeam.membership_json(@membership.reload).merge(invitation_token: token)
  rescue OrganizationTeam::TeamError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def invitation_link
    render json: { invitation_token: OrganizationTeam.invitation_token(@membership) }
  rescue OrganizationTeam::TeamError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def transfer_ownership
    return unless authorize_organization!(:manage_organization)

    OrganizationTeam.transfer_ownership!(organization: current_organization, to_membership: @membership,
      actor: current_user, request: request)
    memberships = current_organization.organization_memberships.includes(:user).order(:id)
    render json: memberships.map { |membership| OrganizationTeam.membership_json(membership) }
  rescue OrganizationTeam::TeamError => e
    render json: { error: e.message }, status: :unprocessable_entity
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
end
