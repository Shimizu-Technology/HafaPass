# frozen_string_literal: true

# Admin team management inside any organization, with the same rules as the
# organizer's own Settings page. Admins may also invite an Owner when the
# organization has none (for example after the original invite expired).
class Api::V1::Admin::OrganizationMembershipsController < Api::V1::Admin::BaseController
  before_action :set_organization
  before_action :set_membership, except: [:index, :create]

  def index
    render json: memberships_json
  end

  def create
    # OrganizationTeam refuses a second owner (active or invited).
    membership, token = OrganizationTeam.invite!(organization: @organization, email: params[:email],
      role: params[:role], actor: current_user, request: request, allow_owner: true)
    render json: OrganizationTeam.membership_json(membership).merge(OrganizationTeam.link_json(token)), status: :created
  rescue OrganizationTeam::TeamError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def update
    OrganizationTeam.change_role!(membership: @membership, role: params[:role], actor: current_user, request: request)
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
    render json: OrganizationTeam.membership_json(@membership.reload).merge(OrganizationTeam.link_json(token))
  rescue OrganizationTeam::TeamError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def invitation_link
    render json: OrganizationTeam.link_json(OrganizationTeam.invitation_token(@membership))
  rescue OrganizationTeam::TeamError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def transfer_ownership
    OrganizationTeam.transfer_ownership!(organization: @organization, to_membership: @membership,
      actor: current_user, request: request)
    render json: memberships_json
  rescue OrganizationTeam::TeamError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def set_organization
    @organization = Organization.find(params[:organization_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Organization not found" }, status: :not_found
  end

  def set_membership
    return unless @organization

    @membership = @organization.organization_memberships.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Membership not found" }, status: :not_found
  end

  def memberships_json
    @organization.organization_memberships.includes(:user).order(:id)
      .map { |membership| OrganizationTeam.membership_json(membership) }
  end
end
