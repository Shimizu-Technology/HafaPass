# frozen_string_literal: true

# Brings every saved wallet pass of one event up to date after an event
# change: the shared Google event class once, then a sync per pass in batches.
class WalletPassFanoutJob < ApplicationJob
  queue_as :default

  BATCH_SIZE = 500

  retry_on Wallet::GoogleWalletClient::RetryableError, wait: :polynomially_longer, attempts: 8

  def perform(event_id)
    event = Event.find_by(id: event_id)
    return unless event

    passes = WalletPass.joins(:ticket).where(tickets: { event_id: event_id })
    passes.in_batches(of: BATCH_SIZE) do |batch|
      ActiveJob.perform_all_later(batch.ids.map { |id| WalletPassSyncJob.new(id) })
    end
    # After the per-pass syncs are queued, so a class retry never holds them up.
    sync_google_class(event) if passes.google.exists?
  end

  private

  def sync_google_class(event)
    Wallet::PassSync.sync_google_class(event)
  rescue Wallet::GoogleWalletClient::RetryableError
    raise
  rescue Wallet::GoogleWalletClient::Error => e
    # Objects still update; the class is retried at the next event change.
    Sentry.capture_exception(e, extra: { event_id: event.id })
  end
end
