# frozen_string_literal: true

# Admin console for organizations: find any organization, see its team, and
# set one up on someone's behalf. Team changes go through OrganizationTeam,
# the same rules organizers follow.
class Api::V1::Admin::OrganizationsController < Api::V1::Admin::BaseController
  include AdminListing

  def index
    scope = Organization.order(created_at: :desc, id: :desc)
    if (term = search_term)
      scope = scope.left_joins(:organizer_profile).where(
        "organizations.name ILIKE :q OR organizations.slug ILIKE :q OR organizer_profiles.business_name ILIKE :q",
        q: like_pattern(term)
      )
    end
    organizations, meta = admin_page(scope.includes(:organizer_profile, :organizer_tax_information, organization_memberships: :user))
    render json: { organizations: organizations.map { |organization| organization_summary(organization) }, meta: meta }
  end

  def show
    response.headers["Cache-Control"] = "no-store"
    organization = Organization.find(params[:id])
    render json: organization_detail(organization)
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Organization not found" }, status: :not_found
  end

  # "Create organization for someone": a new organization with its organizer
  # profile and an emailed Owner invitation. Pre-verifying skips the identity
  # review only; the owner still accepts the organizer agreement themselves.
  def create
    name = params[:name].to_s.strip
    owner_email = params[:owner_email].to_s.strip.downcase
    pre_verified = ActiveModel::Type::Boolean.new.cast(params[:pre_verified])
    return render json: { error: "Enter the organization name" }, status: :unprocessable_entity if name.blank?
    unless owner_email.match?(URI::MailTo::EMAIL_REGEXP)
      return render json: { error: "Enter the owner's email address" }, status: :unprocessable_entity
    end

    organization = nil
    membership = nil
    token = nil
    ActiveRecord::Base.transaction do
      organization = Organization.create!(name: name)
      profile = organization.create_organizer_profile!(business_name: name, user: nil)
      if pre_verified
        profile.update!(verification_status: :verified, verified_at: Time.current, verified_by_user: current_user,
          verification_notes: nil)
      end
      AuditLogger.record!(action: "organization.created_by_admin", auditable: organization, actor: current_user,
        organization: organization, after_data: { name: name, owner_email: owner_email, pre_verified: pre_verified },
        request: request)
      membership, token = OrganizationTeam.invite!(organization: organization, email: owner_email, role: "owner",
        actor: current_user, request: request, allow_owner: true, deliver: false)
    end
    EmailService.send_organization_invitation_async(membership, requested_by: current_user)
    render json: organization_detail(organization.reload).merge(OrganizationTeam.link_json(token)), status: :created
  rescue OrganizationTeam::TeamError => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
  end

  private

  def organization_summary(organization)
    memberships = organization.organization_memberships
    owner = memberships.find { |membership| membership.owner? && membership.status_active? } ||
      memberships.find { |membership| membership.owner? && membership.status_invited? }
    profile = organization.organizer_profile
    {
      id: organization.id,
      name: organization.name,
      slug: organization.slug,
      status: organization.status,
      created_at: organization.created_at,
      owner: owner && { email: owner.user&.email || owner.invited_email, invitation_status: owner.invitation_status },
      members_count: memberships.count(&:effective?),
      pending_invitations_count: memberships.count(&:invitation_open?),
      verification_status: profile&.verification_status,
      payout_ready: organization.payout_ready?
    }
  end

  def organization_detail(organization)
    profile = organization.organizer_profile
    organization_summary(organization).merge(
      tax_information: organization.organizer_tax_information&.safe_json,
      payout_accounts: organization.connected_accounts.order(updated_at: :desc, id: :desc).map { |account| PayoutMethodReview.account_json(account) },
      timezone: organization.timezone,
      events_count: organization.events.count,
      organizer_profile: profile && {
        id: profile.id,
        business_name: profile.business_name,
        verification_status: profile.verification_status,
        policy_accepted: profile.policy_accepted?
      },
      memberships: organization.organization_memberships.includes(:user).order(:id)
        .map { |membership| OrganizationTeam.membership_json(membership) }
    )
  end
end
