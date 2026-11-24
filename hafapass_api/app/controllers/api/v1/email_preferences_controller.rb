# frozen_string_literal: true

class Api::V1::EmailPreferencesController < ApplicationController
  skip_before_action :authenticate_user!, only: [:show, :update]
  before_action :verify_token, only: [:show, :update]

  def account
    return head :forbidden unless ClerkIdentity.email_matches?(user: current_user, email: current_user.email)

    render json: { url: EmailPreferences.url(current_user.email) }
  end

  def show
    render json: snapshot
  end

  def update
    EmailPreferences.with_platform_locks(@email, create_subscriber: params.key?(:platform) || params[:unsubscribe_all] == true,
      subscriber_attributes: { source: "preferences", status: "unsubscribed" }) do |preference, subscriber|
      EmailPreferences.lock_follows!(@email)
      if params[:unsubscribe_all] == true
        preference.update!(all_unsubscribed: true)
        EmailPreferences.organizations(@email).find_each do |org|
          MarketingUnsubscribe.find_or_initialize_by(organization: org, email: @email).update!(unsubscribed_at: Time.current)
        end
        clear_follow_consent(OrganizerFollow.where(email_opted_in_address: @email))
        EmailPreferences.unsubscribe_locked_platform!(@email, subscriber)
        EmailConsent.record!(email: @email, scope: "all", action: "unsubscribed", source: "preferences", request: request)
      else
        if params[:platform] == false
          EmailPreferences.unsubscribe_locked_platform!(@email, subscriber)
        elsif params[:platform] == true && !%w[bounced complained].include?(subscriber.status)
          EmailPreferences.restore_scope!(preference: preference, subscriber: subscriber)
          # The signed preferences token proves this address.
          subscriber.update!(status: "confirmed", confirmed_at: Time.current, confirmation_nonce: SecureRandom.hex(24))
          EmailConsent.record!(email: @email, scope: "platform", action: "confirmed", source: "preferences", request: request)
        end
        params.permit(organizers: [:id, :enabled]).fetch(:organizers, []).each do |choice|
          org = EmailPreferences.organizations(@email).find(choice[:id])
          follows = OrganizerFollow.where(organization: org, email_opted_in_address: @email)
          if choice[:enabled] == true
            EmailPreferences.restore_scope!(preference: preference, subscriber: subscriber, organization: org)
            follows.update_all(email_opted_in_at: Time.current, email_opted_in_address: @email,
              email_consent_version: EmailConsent.version_for(scope: "organizer", source: "preferences"))
          else
            MarketingUnsubscribe.find_or_initialize_by(organization: org, email: @email).update!(unsubscribed_at: Time.current)
            clear_follow_consent(follows)
          end
          EmailConsent.record!(email: @email, organization: org, scope: "organizer", action: choice[:enabled] == true ? "confirmed" : "unsubscribed", source: "preferences", request: request)
        end
      end
    end
    render json: snapshot
  end

  private

  def clear_follow_consent(follows)
    follows.update_all(email_opted_in_at: nil)
  end

  def verify_token
    response.set_header("Cache-Control", "private, no-store")
    @email = EmailPreferences.email(params[:token])
    render json: { error: "Invalid or expired link" }, status: :unprocessable_entity unless @email
  end

  def snapshot
    { platform: PlatformSubscriber.find_by(email: @email)&.mailable? || false,
      all_unsubscribed: EmailPreference.blocked?(@email),
      organizers: EmailPreferences.organizations(@email).map { |org| { id: org.id, name: org.name, enabled: EmailPreferences.organizer_enabled?(org, @email) } } }
  end
end
