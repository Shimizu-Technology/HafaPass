# frozen_string_literal: true

# Queues a sync for every saved wallet pass of one event, in batches.
class WalletPassFanoutJob < ApplicationJob
  queue_as :default

  BATCH_SIZE = 500

  def perform(event_id)
    WalletPass.joins(:ticket).where(tickets: { event_id: event_id }).in_batches(of: BATCH_SIZE) do |batch|
      ActiveJob.perform_all_later(batch.ids.map { |id| WalletPassSyncJob.new(id) })
    end
  end
end
