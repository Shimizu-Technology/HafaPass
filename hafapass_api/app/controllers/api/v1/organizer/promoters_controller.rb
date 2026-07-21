# frozen_string_literal: true

class Api::V1::Organizer::PromotersController < Api::V1::Organizer::EventResourcesController
  def index
    render json: { promoters: event.promoters.order(:name, :id).map { |item| serialize(item) } }
  end

  def create
    render_record(event.promoters.build(record_params), status: :created)
  end

  def update
    item = event.promoters.find(params[:id])
    item.assign_attributes(record_params)
    render_record(item)
  end

  def destroy
    destroy_record(event.promoters.find(params[:id]))
  end

  private

  def resource_permission
    :manage_marketing
  end

  def record_params
    params.permit(:name, :email, :code, :commission_bps, :active)
  end

  def serialize(item)
    entries = item.promoter_commission_entries
    item.as_json(only: [:id, :name, :email, :code, :commission_bps, :active]).merge(
      attributed_orders: item.referral_attributions.count,
      earned_cents: entries.earned.sum(:amount_cents),
      reversed_cents: entries.refund_reversal.sum(:amount_cents).abs,
      net_commission_cents: entries.sum(:amount_cents)
    )
  end
end
