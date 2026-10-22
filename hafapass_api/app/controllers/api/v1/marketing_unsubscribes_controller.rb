# frozen_string_literal: true

class Api::V1::MarketingUnsubscribesController < ApplicationController
  skip_before_action :authenticate_user!

  def show
    if (entry = WaitlistUnsubscribe.from_token(params[:token]))
      return render json: { organization: entry.event.organization.name, event: entry.event.title,
        scope: "waitlist", unsubscribed: entry.cancelled? }
    end
    organization, email = verified_identity
    return unless organization

    render json: { organization: organization.name, scope: "organizer",
      unsubscribed: MarketingUnsubscribe.exists?(organization: organization, email: email) }
  end

  def create
    if (entry = WaitlistUnsubscribe.from_token(params[:token]))
      all = params[:scope] == "organizer"
      WaitlistUnsubscribe.stop!(entry, all: all)
      return render json: { organization: entry.event.organization.name, scope: all ? "organizer" : "waitlist",
        unsubscribed: true }
    end
    organization, email = verified_identity
    return unless organization

    organization.with_lock do
      record = MarketingUnsubscribe.find_or_initialize_by(organization: organization, email: email)
      record.update!(unsubscribed_at: Time.current)
    end
    render json: { organization: organization.name, scope: "organizer", unsubscribed: true }
  end

  private

  def verified_identity
    identity = MarketingUnsubscribe.from_token(params[:token])
    if identity.nil? || identity.first.nil?
      render json: { error: "This unsubscribe link is invalid" }, status: :unprocessable_entity
      return [nil, nil]
    end
    identity
  end
end
