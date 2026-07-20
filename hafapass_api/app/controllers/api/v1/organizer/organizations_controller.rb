# frozen_string_literal: true

class Api::V1::Organizer::OrganizationsController < ApplicationController
  def index
    memberships = current_user.organization_memberships.effective.includes(:organization).order(:id)
    render json: memberships.map { |membership| organization_json(membership.organization, membership.role) }
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
      payout_ready: organization.payout_ready?
    }
  end
end
