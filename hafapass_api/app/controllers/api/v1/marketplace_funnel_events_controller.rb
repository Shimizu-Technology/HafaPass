# frozen_string_literal: true

class Api::V1::MarketplaceFunnelEventsController < ApplicationController
  skip_before_action :authenticate_user!

  def create
    event = Event.discoverable.find(params[:event_id])
    stage = params[:stage].to_s
    unless %w[event_view checkout_started].include?(stage)
      return render json: { error: "Unsupported funnel stage" }, status: :unprocessable_entity
    end

    link = DistributionLink.available.find_by(code: params[:distribution_code].to_s.upcase)
    referral = EventReferral.find_by(code: params[:event_referral_code].to_s.upcase, active: true)
    if link && link.event_id != event.id
      return render json: { error: "Distribution link does not match this event" }, status: :unprocessable_entity
    end
    if referral && referral.event_id != event.id
      return render json: { error: "Referral does not match this event" }, status: :unprocessable_entity
    end

    source, medium, campaign = trusted_attribution(link, referral)
    MarketplaceFunnelEvent.create!(
      event: event,
      distribution_link: link,
      event_referral: referral,
      visitor_hash: Marketplace::VisitorIdentity.hash(params[:anonymous_id]),
      stage: stage,
      source: source,
      medium: medium,
      campaign: campaign,
      occurred_at: Time.current
    )
    head :created
  rescue Marketplace::VisitorIdentity::InvalidIdentifier => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def trusted_attribution(link, referral)
    return ["user_referral", "share", referral.code] if referral
    return [link.distribution_partner.kind, "partner", link.campaign] if link

    [limited_value(params[:source]), limited_value(params[:medium]), limited_value(params[:campaign])]
  end

  def limited_value(value)
    normalized = value.to_s.strip.first(100)
    normalized if normalized.match?(/\A[a-zA-Z0-9._-]+\z/)
  end
end
