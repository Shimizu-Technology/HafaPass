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
    before_address = organization.marketing_mailing_address
    before_certified_at = organization.marketing_address_certified_at
    submitted_certification = ActiveModel::Type::Boolean.new.cast(params.dig(:organization, :certified))
    organization.marketing_mailing_address = address.presence
    organization.marketing_address_certified_at =
      submitted_certification ? Time.current : nil
    saved = Organization.transaction do
      if organization.save
        AuditLogger.record!(action: "organization.marketing_postal_address_updated", auditable: organization,
          actor: current_user, request: request,
          before_data: { marketing_mailing_address: before_address, marketing_address_certified_at: before_certified_at },
          after_data: { marketing_mailing_address: organization.marketing_mailing_address,
            marketing_address_certified_at: organization.marketing_address_certified_at,
            submitted_certification: submitted_certification })
        true
      else
        false
      end
    end
    if saved
      render json: organization_json(organization, organization.organization_memberships.find_by(user: current_user)&.role)
    else
      render json: { errors: organization.errors.full_messages }, status: :unprocessable_entity
    end
  end

  private

  def organization_json(organization, role)
    activity = OrganizationActivityAccess.new(user: current_user, organization: organization)
    {
      id: organization.id,
      name: organization.name,
      slug: organization.slug,
      status: organization.status,
      timezone: organization.timezone,
      currency: organization.currency,
      role: role,
      activity_access: activity.allowed?,
      activity_scope: activity.fingerprint,
      permissions: OrganizationAuthorization.permissions_for(user: current_user, organization: organization),
      payout_ready: organization.payout_ready?,
      marketing_mailing_address: organization.marketing_mailing_address,
      marketing_address_ready: organization.marketing_postal_address_ready?,
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
