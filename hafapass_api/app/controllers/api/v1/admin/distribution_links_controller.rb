# frozen_string_literal: true

class Api::V1::Admin::DistributionLinksController < Api::V1::Admin::BaseController
  def index
    links = DistributionLink.includes(:event, :distribution_partner).order(created_at: :desc)
    render json: { distribution_links: links.map { |link| serialize(link) } }
  end

  def create
    persist(DistributionLink.new(link_params.merge(created_by_user: current_user)), :created)
  end

  def update
    link = DistributionLink.find(params[:id])
    link.assign_attributes(link_params)
    persist(link)
  end

  def destroy
    DistributionLink.find(params[:id]).update!(active: false)
    head :no_content
  end

  private

  def link_params
    params.permit(:distribution_partner_id, :event_id, :campaign, :active, :expires_at)
  end

  def persist(link, status = :ok)
    if link.save
      render json: serialize(link), status: status
    else
      render json: { errors: link.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def serialize(link)
    {
      id: link.id, code: link.code, campaign: link.campaign, active: link.active, expires_at: link.expires_at,
      event: { id: link.event.id, title: link.event.title, slug: link.event.slug },
      partner: { id: link.distribution_partner.id, name: link.distribution_partner.name,
        kind: link.distribution_partner.kind },
      url: "#{ENV.fetch('FRONTEND_URL', 'http://localhost:5173')}/go/#{link.code}"
    }
  end
end
