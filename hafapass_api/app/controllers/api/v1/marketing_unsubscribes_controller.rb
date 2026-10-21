# frozen_string_literal: true

class Api::V1::MarketingUnsubscribesController < ApplicationController
  skip_before_action :authenticate_user!

  def show
    organization, email = verified_identity
    return unless organization

    render json: { organization: organization.name,
      unsubscribed: MarketingUnsubscribe.exists?(organization: organization, email: email) }
  end

  def create
    organization, email = verified_identity
    return unless organization

    organization.with_lock do
      record = MarketingUnsubscribe.find_or_initialize_by(organization: organization, email: email)
      record.update!(unsubscribed_at: Time.current)
    end
    render json: { organization: organization.name, unsubscribed: true }
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
