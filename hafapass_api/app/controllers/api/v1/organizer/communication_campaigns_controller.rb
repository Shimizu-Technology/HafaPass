# frozen_string_literal: true

class Api::V1::Organizer::CommunicationCampaignsController < Api::V1::Organizer::EventResourcesController
  def index
    render json: { communication_campaigns: event.communication_campaigns.order(created_at: :desc).map { |item| serialize(item) } }
  end

  def create
    campaign = event.communication_campaigns.build(record_params.merge(created_by_user: current_user))
    if campaign.save
      schedule(campaign)
      render json: serialize(campaign), status: :created
    else
      render json: { errors: campaign.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    campaign = editable_campaign
    return unless campaign

    campaign.assign_attributes(record_params)
    if campaign.save
      schedule(campaign)
      render json: serialize(campaign)
    else
      render json: { errors: campaign.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    campaign = editable_campaign
    return unless campaign

    destroy_record(campaign)
  end

  def send_now
    campaign = event.communication_campaigns.find(params[:id])
    CommunicationCampaigns::Sender.call(campaign)
    render json: serialize(campaign.reload), status: :accepted
  rescue CommunicationCampaigns::Sender::CampaignError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def resource_permission
    :manage_marketing
  end

  def editable_campaign
    campaign = event.communication_campaigns.find(params[:id])
    return campaign if campaign.draft? || campaign.scheduled?

    render json: { error: "Only draft or scheduled campaigns can be changed" }, status: :unprocessable_entity
    nil
  end

  def record_params
    params.permit(:name, :subject, :body, :scheduled_at, segment: [:type, :ticket_type_id])
  end

  def schedule(campaign)
    return unless campaign.scheduled_at&.future?

    campaign.update!(status: :scheduled)
    CommunicationCampaignJob.set(wait_until: campaign.scheduled_at).perform_later(campaign.id)
  end

  def serialize(campaign)
    campaign.as_json(only: [:id, :name, :subject, :body, :segment, :status, :scheduled_at,
      :started_at, :sent_at, :recipient_count, :created_at])
  end
end
