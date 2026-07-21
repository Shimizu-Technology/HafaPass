# frozen_string_literal: true

class Api::V1::Admin::DistributionPartnersController < Api::V1::Admin::BaseController
  def index
    render json: { distribution_partners: DistributionPartner.order(:name) }
  end

  def create
    persist(DistributionPartner.new(partner_params), :created)
  end

  def update
    partner = DistributionPartner.find(params[:id])
    partner.assign_attributes(partner_params)
    persist(partner)
  end

  def destroy
    DistributionPartner.find(params[:id]).update!(active: false)
    head :no_content
  end

  private

  def partner_params
    params.permit(:name, :slug, :kind, :website_url, :contact_name, :contact_email, :active)
  end

  def persist(partner, success = :ok)
    if partner.save
      render json: partner, status: success
    else
      render json: { errors: partner.errors.full_messages }, status: :unprocessable_entity
    end
  end
end
