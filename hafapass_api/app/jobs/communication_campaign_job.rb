# frozen_string_literal: true

class CommunicationCampaignJob < ApplicationJob
  queue_as :emails

  def perform(campaign_id, scheduled_for = nil)
    campaign = CommunicationCampaign.find(campaign_id)
    return unless campaign.scheduled? && campaign.scheduled_at <= Time.current
    return if scheduled_for && campaign.scheduled_at.utc.iso8601 != scheduled_for

    CommunicationCampaigns::Sender.call(campaign)
  rescue CommunicationCampaigns::Sender::CampaignError
    nil
  end
end
