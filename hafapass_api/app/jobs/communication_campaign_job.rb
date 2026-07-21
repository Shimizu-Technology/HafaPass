# frozen_string_literal: true

class CommunicationCampaignJob < ApplicationJob
  queue_as :emails

  def perform(campaign_id)
    campaign = CommunicationCampaign.find(campaign_id)
    return unless campaign.scheduled? && campaign.scheduled_at <= Time.current

    CommunicationCampaigns::Sender.call(campaign)
  rescue CommunicationCampaigns::Sender::CampaignError
    nil
  end
end
