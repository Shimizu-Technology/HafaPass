# frozen_string_literal: true

class Api::V1::Me::OrganizerFollowsController < ApplicationController
  def index
    follows = current_user.organizer_follows.to_a
    ids = follows.map(&:organization_id)
    enabled_ids = EmailPreferences.organizer_enabled_ids(ids, current_user.email)
    markers = EmailPreferences.consent_markers(ids, current_user.email,
      saved_addresses: follows.to_h { |follow| [follow.organization_id, follow.email_opted_in_address] })
    render json: { organizers: current_user.followed_organizations.includes(:organizer_profile).order(:name).map { |org|
      { id: org.id, name: org.organizer_profile.business_name, slug: org.slug, logo_url: org.organizer_profile.logo_url,
        verified: org.organizer_profile.verification_status_verified?,
        email_opt_in: enabled_ids.include?(org.id), consent_marker: markers.fetch(org.id) }
    } }
  end

  def create
    organization = Organization.status_active.find(params[:organization_id])
    follow = current_user.organizer_follows.find_by(organization: organization)
    if params.key?(:email_opt_in)
      return head :forbidden unless ClerkIdentity.email_matches?(user: current_user, email: current_user.email)
    end
    enabled = params[:email_opt_in] == true
    email = (enabled ? current_user.email : follow&.email_opted_in_address.presence || current_user.email).to_s.strip.downcase
    EmailPreferences.with_platform_locks_for([current_user.email, follow&.email_opted_in_address]) do
      preference = EmailPreference.find_by!(email: email)
      subscriber = PlatformSubscriber.find_by(email: email)
      follow = if params[:consent_only] == true
        current_user.organizer_follows.lock.find_by!(organization: organization)
      else
        current_user.organizer_follows.find_or_create_by!(organization: organization)
      end
      follow.lock!
      if params.key?(:email_opt_in)
        if params[:consent_only] == true && params[:consent_marker] != EmailPreferences.consent_markers([organization.id], current_user.email,
            saved_addresses: { organization.id => follow.email_opted_in_address }).fetch(organization.id)
          return render json: { error: "Email preferences changed; reload before choosing again" }, status: :conflict
        end
        if enabled
          EmailPreferences.restore_scope!(preference: preference, subscriber: subscriber, organization: organization)
        else
          [current_user.email, follow.email_opted_in_address].compact.map { |address| address.strip.downcase }.uniq.each do |address|
            MarketingUnsubscribe.find_or_initialize_by(organization: organization, email: address).update!(unsubscribed_at: Time.current)
          end
        end
        follow.update!(email_opted_in_at: enabled ? Time.current : nil, email_opted_in_address: enabled ? email : follow.email_opted_in_address,
          email_consent_version: EmailConsent.version_for(scope: "organizer", source: "follow"))
        addresses = enabled ? [email] : [current_user.email, follow.email_opted_in_address].compact.map { |address| address.strip.downcase }.uniq
        addresses.each do |address|
          EmailConsent.record!(email: address, organization: organization, scope: "organizer",
            action: enabled ? "confirmed" : "unsubscribed", source: "follow", request: request)
        end
      end
    end
    render json: { id: follow.id, organization_id: organization.id }, status: :created
  end

  def destroy
    follow = current_user.organizer_follows.find_by!(organization_id: params[:organization_id])
    email = (follow.email_opted_in_address.presence || current_user.email).strip.downcase
    EmailPreferences.with_platform_locks(email, create_preference: false) do
      follow.lock!
      MarketingUnsubscribe.find_or_initialize_by(organization: follow.organization, email: email).update!(unsubscribed_at: Time.current)
      EmailConsent.record!(email: email, organization: follow.organization, scope: "organizer", action: "unsubscribed", source: "follow", request: request)
      follow.destroy!
    end
    head :no_content
  end
end
