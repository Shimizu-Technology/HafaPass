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
    EmailPreference.transaction do
      preference = EmailPreference.find_or_create_by!(email: @email)
      preference.lock!
      if params[:unsubscribe_all] == true
        preference.update!(all_unsubscribed: true)
        EmailPreferences.organizations(@email).find_each do |org|
          MarketingUnsubscribe.find_or_initialize_by(organization: org, email: @email).update!(unsubscribed_at: Time.current)
        end
        EmailPreferences.unsubscribe_platform!(@email)
        EmailConsent.record!(email: @email, scope: "all", action: "unsubscribed", source: "preferences", request: request)
      else
        if params.key?(:platform)
          subscriber = PlatformSubscriber.find_by(email: @email)
          if subscriber.nil? && params[:platform] == true
            subscriber = PlatformSubscriber.create!(email: @email, source: "preferences")
          end
          if params[:platform] == false
            EmailPreferences.unsubscribe_platform!(@email)
          elsif subscriber && params[:platform] == true && !%w[bounced complained].include?(subscriber.status)
            preference.update!(all_unsubscribed: false)
            subscriber.update!(status: "pending", confirmation_nonce: SecureRandom.hex(24))
            # Possession of the signed preferences token proves this address; record the affirmative choice.
            subscriber.update!(status: "confirmed", confirmed_at: Time.current)
            EmailConsent.record!(email: @email, scope: "platform", action: "confirmed", source: "preferences", request: request)
          end
        end
        Array(params[:organizers]).each do |choice|
          org = EmailPreferences.organizations(@email).find(choice[:id])
          if choice[:enabled] == true
            preference.update!(all_unsubscribed: false)
            MarketingUnsubscribe.where(organization: org, email: @email).delete_all
            # Existing follower relationships alone are never email consent.
            OrganizerFollow.joins(:user).where(organization: org).where("LOWER(users.email) = ?", @email)
              .update_all(email_opted_in_at: Time.current, email_consent_version: EmailConsent::VERSION)
          else
            MarketingUnsubscribe.find_or_initialize_by(organization: org, email: @email).update!(unsubscribed_at: Time.current)
          end
          EmailConsent.record!(email: @email, organization: org, scope: "organizer", action: choice[:enabled] == true ? "confirmed" : "unsubscribed", source: "preferences", request: request)
        end
      end
    end
    render json: snapshot
  end

  private

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
