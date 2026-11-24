# frozen_string_literal: true

class Api::V1::Me::OrganizerFollowsController < ApplicationController
  def index
    render json: { organizers: current_user.followed_organizations.includes(:organizer_profile).order(:name).map { |org|
      { id: org.id, name: org.organizer_profile.business_name, slug: org.slug, logo_url: org.organizer_profile.logo_url,
        verified: org.organizer_profile.verification_status_verified?,
        email_opt_in: current_user.organizer_follows.find_by(organization: org)&.email_opted_in_at.present? }
    } }
  end

  def create
    organization = Organization.status_active.find(params[:organization_id])
    follow = current_user.organizer_follows.find_or_create_by!(organization: organization)
    if params.key?(:email_opt_in)
      return head :forbidden unless ClerkIdentity.email_matches?(user: current_user, email: current_user.email)
      follow.with_lock do
        enabled = params[:email_opt_in] == true
        if enabled
          MarketingUnsubscribe.where(organization: organization, email: current_user.email.downcase).delete_all
        else
          MarketingUnsubscribe.find_or_initialize_by(organization: organization, email: current_user.email.downcase).update!(unsubscribed_at: Time.current)
        end
        follow.update!(email_opted_in_at: enabled ? Time.current : nil, email_consent_version: EmailConsent::VERSION)
        EmailConsent.record!(email: current_user.email, organization: organization, scope: "organizer",
          action: enabled ? "confirmed" : "unsubscribed", source: "follow", request: request)
      end
    end
    render json: { id: follow.id, organization_id: organization.id }, status: :created
  end

  def destroy
    current_user.organizer_follows.find_by!(organization_id: params[:organization_id]).destroy!
    head :no_content
  end
end
