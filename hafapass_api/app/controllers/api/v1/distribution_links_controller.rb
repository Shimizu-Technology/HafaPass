# frozen_string_literal: true

class Api::V1::DistributionLinksController < ApplicationController
  skip_before_action :authenticate_user!

  def show
    link = DistributionLink.available.includes(:event, :distribution_partner).find_by!(code: params[:code].to_s.upcase)
    visitor_hash = Marketplace::VisitorIdentity.hash(params[:anonymous_id])
    MarketplaceFunnelEvent.create!(
      event: link.event,
      distribution_link: link,
      visitor_hash: visitor_hash,
      stage: :landing,
      source: link.distribution_partner.kind,
      medium: "partner",
      campaign: link.campaign,
      occurred_at: Time.current
    )
    render json: {
      event_slug: link.event.slug,
      attribution: { distribution_code: link.code, source: link.distribution_partner.kind,
        medium: "partner", campaign: link.campaign }
    }
  rescue Marketplace::VisitorIdentity::InvalidIdentifier => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
end
