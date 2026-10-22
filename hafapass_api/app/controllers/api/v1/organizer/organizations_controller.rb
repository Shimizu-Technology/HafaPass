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
      fee_change_notice: fee_change_notice(organization, role),
      admin_view: current_user.admin? && role.nil?
    }
  end

  def fee_change_notice(organization, role)
    return unless role == "owner"

    notice = FeeChangeNotice.joins(:fee_change).where(organization: organization, owner: current_user,
      fee_changes: { activated_at: nil })
      .where("fee_changes.effective_at > ?", Time.current).order("fee_changes.effective_at").first
    return unless notice

    change = notice.fee_change
    { id: notice.id, effective_at: change.effective_at, acknowledged_at: notice.acknowledged_at,
      old_terms: change.old_terms,
      new_terms: change.new_terms, old_example: notice.example(change.old_terms),
      new_example: notice.example(change.new_terms) }
  end

  def admin_requested_organization
    requested_id = request.headers["X-Organization-Id"].presence || params[:organization_id].presence
    requested_id && Organization.find_by(id: requested_id)
  end
end
