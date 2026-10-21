# frozen_string_literal: true

class Api::V1::MarketingUnsubscribesController < ApplicationController
  skip_before_action :authenticate_user!

  def show
    organization, email = verified_identity
    return unless organization

    MarketingUnsubscribe.find_or_create_by!(organization: organization, email: email) do |record|
      record.unsubscribed_at = Time.current
    end
    render json: { organization: organization.name, unsubscribed: true }
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    raise unless MarketingUnsubscribe.exists?(organization: organization, email: email)

    render json: { organization: organization.name, unsubscribed: true }
  end

  def create
    show
  end

  def destroy
    organization, email = verified_identity
    return unless organization

    MarketingUnsubscribe.where(organization: organization, email: email).delete_all
    render json: { organization: organization.name, unsubscribed: false }
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
