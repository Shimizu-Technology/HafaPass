# frozen_string_literal: true

class Api::V1::EventReferralsController < ApplicationController
  skip_before_action :authenticate_user!

  def show
    referral = EventReferral.includes(:event).find_by!(code: params[:code].to_s.upcase, active: true)
    MarketplaceFunnelEvent.create!(
      event: referral.event,
      event_referral: referral,
      visitor_hash: Marketplace::VisitorIdentity.hash(params[:anonymous_id]),
      stage: :landing,
      source: "user_referral",
      medium: "share",
      campaign: referral.code,
      occurred_at: Time.current
    )
    render json: { event_slug: referral.event.slug,
      attribution: { event_referral_code: referral.code, source: "user_referral", medium: "share",
        campaign: referral.code } }
  rescue Marketplace::VisitorIdentity::InvalidIdentifier => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
end
