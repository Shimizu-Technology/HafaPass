# frozen_string_literal: true

module Operations
  class CommerceClock
    FEE_SWEEP_INTERVAL = 5.minutes

    def initialize
      @last_marketplace_purge_date = nil
      @next_fee_sweep_at = nil
    end

    def tick(at: Time.current)
      ExpireInventoryHoldsJob.perform_later(at)
      ExpireSeatHoldsJob.perform_later(at)
      if @next_fee_sweep_at.nil? || at >= @next_fee_sweep_at
        SweepPendingStripeFeesJob.perform_later
        @next_fee_sweep_at = at + FEE_SWEEP_INTERVAL
      end
      return if @last_marketplace_purge_date == at.to_date

      PurgeMarketplaceAnalyticsJob.perform_later(at: at)
      @last_marketplace_purge_date = at.to_date
    end
  end
end
