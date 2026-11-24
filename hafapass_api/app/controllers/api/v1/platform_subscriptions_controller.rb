# frozen_string_literal: true

class Api::V1::PlatformSubscriptionsController < ApplicationController
  skip_before_action :authenticate_user!

  def create
    PlatformSubscription.call(params.permit(:email, :name, :source, interests: [], villages: []).to_h.symbolize_keys, request: request)
    render json: { accepted: true }, status: :accepted
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    render json: { accepted: true }, status: :accepted
  end

  def confirm
    subscriber = PlatformSubscriber.confirm!(params[:token])
    render json: { confirmed: subscriber.present? }, status: subscriber ? :ok : :unprocessable_entity
  end

  def unsubscribe
    email = EmailPreferences.email(params[:token], scope: "platform_unsubscribe")
    return render json: { error: "Invalid link" }, status: :unprocessable_entity unless email

    EmailPreferences.unsubscribe_platform!(email)
    render json: { unsubscribed: true }
  end
end
