# frozen_string_literal: true

class Api::V1::Me::EventReferralsController < ApplicationController
  def index
    render json: { referrals: current_user.event_referrals.includes(:event).order(created_at: :desc).map { |referral|
      referral_json(referral)
    } }
  end

  def create
    event = Event.publicly_visible.find(params[:event_id])
    referral = current_user.event_referrals.find_or_create_by!(event: event)
    render json: referral_json(referral), status: :created
  end

  private

  def referral_json(referral)
    {
      id: referral.id,
      event_id: referral.event_id,
      code: referral.code,
      url: "#{ENV.fetch('FRONTEND_URL', 'http://localhost:5173')}/refer/#{referral.code}",
      visits: referral.marketplace_funnel_events.landing.count,
      purchases: referral.acquisition_attributions.joins(:order)
        .where(orders: { status: [:completed, :partially_refunded, :refunded] }).count
    }
  end
end
