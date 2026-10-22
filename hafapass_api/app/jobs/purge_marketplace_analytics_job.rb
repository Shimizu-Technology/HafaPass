# frozen_string_literal: true

class PurgeMarketplaceAnalyticsJob < ApplicationJob
  queue_as :low

  RETENTION_PERIOD = 13.months

  def perform(at: Time.current)
    count = 0
    MarketplaceFunnelEvent.where(order_id: nil).where(occurred_at: ...RETENTION_PERIOD.ago(at))
      .in_batches(of: DataRetention::BATCH_SIZE) do |batch|
        batch.each do |event|
          next if DataRetention.held?(event)

          count += 1
          event.destroy! unless DataRetention.dry_run?
        end
      end
    Rails.logger.info("[MarketplaceAnalyticsRetention] dry_run=#{DataRetention.dry_run?} count=#{count}")
    count
  end
end
