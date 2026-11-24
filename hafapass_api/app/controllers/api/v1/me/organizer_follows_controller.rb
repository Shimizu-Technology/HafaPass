# frozen_string_literal: true

class Api::V1::Me::OrganizerFollowsController < ApplicationController
  def index
    enabled_ids = EmailPreferences.organizer_enabled_ids(current_user.organizer_follows.pluck(:organization_id), current_user.email)
    render json: { organizers: current_user.followed_organizations.includes(:organizer_profile).order(:name).map { |org|
      { id: org.id, name: org.organizer_profile.business_name, slug: org.slug, logo_url: org.organizer_profile.logo_url,
        verified: org.organizer_profile.verification_status_verified?,
        email_opt_in: enabled_ids.include?(org.id) }
    } }
  end

  def create
    organization = Organization.status_active.find(params[:organization_id])
    follow = if params[:consent_only] == true
      current_user.organizer_follows.find_by!(organization: organization)
    else
      current_user.organizer_follows.find_or_create_by!(organization: organization)
    end
    if params.key?(:email_opt_in)
      return head :forbidden unless ClerkIdentity.email_matches?(user: current_user, email: current_user.email)
      enabled = params[:email_opt_in] == true
      email = (enabled ? current_user.email : follow.email_opted_in_address.presence || current_user.email).strip.downcase
      EmailPreferences.with_platform_locks(email) do |preference, subscriber|
        follow = current_user.organizer_follows.lock.find_by!(organization: organization)
        follow.with_lock do
          if enabled
            EmailPreferences.restore_scope!(preference: preference, subscriber: subscriber, organization: organization)
          else
            MarketingUnsubscribe.find_or_initialize_by(organization: organization, email: email).update!(unsubscribed_at: Time.current)
          end
          follow.update!(email_opted_in_at: enabled ? Time.current : nil, email_opted_in_address: enabled ? email : nil,
            email_consent_version: EmailConsent.version_for(scope: "organizer", source: "follow"))
          EmailConsent.record!(email: email, organization: organization, scope: "organizer",
            action: enabled ? "confirmed" : "unsubscribed", source: "follow", request: request)
        end
      end
    end
    render json: { id: follow.id, organization_id: organization.id }, status: :created
  end

  def destroy
    follow = current_user.organizer_follows.find_by!(organization_id: params[:organization_id])
    follow.with_lock do
      email = follow.email_opted_in_address.presence || current_user.email.downcase
      MarketingUnsubscribe.find_or_initialize_by(organization: follow.organization, email: email).update!(unsubscribed_at: Time.current)
      EmailConsent.record!(email: email, organization: follow.organization, scope: "organizer", action: "unsubscribed", source: "follow", request: request)
      follow.destroy!
    end
    head :no_content
  end
end
