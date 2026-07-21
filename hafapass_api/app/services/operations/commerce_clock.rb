# frozen_string_literal: true

module Operations
  class CommerceClock
    def initialize
      @last_marketplace_purge_date = nil
    end

    def tick(at: Time.current)
      ExpireInventoryHoldsJob.perform_later(at)
      return if @last_marketplace_purge_date == at.to_date

      PurgeMarketplaceAnalyticsJob.perform_later(at: at)
      @last_marketplace_purge_date = at.to_date
    end
  end
end
