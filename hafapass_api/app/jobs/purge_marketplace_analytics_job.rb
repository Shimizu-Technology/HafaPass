# frozen_string_literal: true

class PurgeMarketplaceAnalyticsJob < ApplicationJob
  queue_as :low

  RETENTION_PERIOD = 13.months

  def perform(at: Time.current)
    count = 0
    MarketplaceFunnelEvent.where(order_id: nil).where(occurred_at: ...RETENTION_PERIOD.ago(at))
      .in_batches(of: DataRetention::BATCH_SIZE) do |batch|
        batch.each do |event|
          next if RetentionGuard.protected?(event)

          LegalHold.with_retention_lock do
            event.with_lock do
              next if RetentionGuard.protected?(event)

              event.destroy!
              count += 1
            end
          end
        end
      end
    Rails.logger.info("[MarketplaceAnalyticsRetention] count=#{count}")
    count
  end
end
