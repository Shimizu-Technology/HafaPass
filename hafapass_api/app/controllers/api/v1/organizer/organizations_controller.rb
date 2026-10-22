# frozen_string_literal: true

class Api::V1::Organizer::OrganizationsController < ApplicationController
  def index
    memberships = current_user.organization_memberships.effective.includes(:organization).order(:id)
    organizations = memberships.map { |membership| organization_json(membership.organization, membership.role) }
    # An admin who opened another organization from the admin console sees it
    # in their switcher, clearly marked, without becoming a member.
    if current_user.admin? && (requested = admin_requested_organization) &&
        organizations.none? { |item| item[:id] == requested.id }
      organizations << organization_json(requested, nil)
    end
    render json: organizations
  end

  def show
    organization = OrganizationContext.resolve(
      user: current_user,
      requested_id: request.headers["X-Organization-Id"].presence || params[:organization_id].presence
    )
    return render json: { error: "Organization membership required" }, status: :forbidden unless organization

    membership = organization.organization_memberships.find_by(user: current_user)
    render json: organization_json(organization, membership&.role)
  end

  def update
    organization = OrganizationContext.resolve(
      user: current_user,
      requested_id: request.headers["X-Organization-Id"].presence || params[:organization_id].presence
    )
    return render json: { error: "Organization membership required" }, status: :forbidden unless organization
    unless OrganizationAuthorization.allowed?(user: current_user, organization: organization, permission: :manage_organization)
      return render json: { error: "Only the organization owner can set the marketing postal address" }, status: :forbidden
    end

    address = params.require(:organization).permit(:marketing_mailing_address)[:marketing_mailing_address].to_s.strip
    organization.marketing_mailing_address = address.presence
    organization.marketing_address_certified_at =
      ActiveModel::Type::Boolean.new.cast(params.dig(:organization, :certified)) ? Time.current : nil
    if organization.save
      render json: organization_json(organization, organization.organization_memberships.find_by(user: current_user)&.role)
    else
      render json: { errors: organization.errors.full_messages }, status: :unprocessable_entity
    end
  end

  private

  def organization_json(organization, role)
    {
      id: organization.id,
      name: organization.name,
      slug: organization.slug,
      status: organization.status,
      timezone: organization.timezone,
      currency: organization.currency,
      role: role,
      permissions: OrganizationAuthorization.permissions_for(user: current_user, organization: organization),
      payout_ready: organization.payout_ready?,
      marketing_mailing_address: organization.marketing_mailing_address,
      marketing_address_ready: organization.marketing_postal_address_ready?,
      admin_view: current_user.admin? && role.nil?
    }
  end

  def admin_requested_organization
    requested_id = request.headers["X-Organization-Id"].presence || params[:organization_id].presence
    requested_id && Organization.find_by(id: requested_id)
  end
end
