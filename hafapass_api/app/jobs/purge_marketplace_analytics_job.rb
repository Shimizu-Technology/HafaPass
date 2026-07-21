# frozen_string_literal: true

class PurgeMarketplaceAnalyticsJob < ApplicationJob
  queue_as :low

  RETENTION_PERIOD = 13.months

  def perform(at: Time.current)
    MarketplaceFunnelEvent.where(order_id: nil).where(occurred_at: ...RETENTION_PERIOD.ago(at)).delete_all
  end
end
