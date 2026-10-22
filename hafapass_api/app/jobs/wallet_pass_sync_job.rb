# frozen_string_literal: true

# Pushes one saved wallet pass's latest state to Apple or Google. Safe to run
# repeatedly: it only contacts the provider while the recorded content differs
# from what was last delivered.
class WalletPassSyncJob < ApplicationJob
  queue_as :default

  RETRYABLE = [
    Wallet::PassSync::RetryableError, Wallet::GoogleWalletClient::RetryableError, Wallet::ApplePushNotifier::DeliveryError
  ].freeze

  retry_on(*RETRYABLE, wait: :polynomially_longer, attempts: 8)

  def perform(wallet_pass_id)
    wallet_pass = WalletPass.find_by(id: wallet_pass_id)
    return unless wallet_pass

    Wallet::PassSync.call(wallet_pass)
  rescue *RETRYABLE => e
    record_failure(wallet_pass, e)
    raise
  rescue Wallet::PassSync::Error, Wallet::GoogleWalletClient::Error => e
    # Not retried automatically; the next ticket change tries again.
    record_failure(wallet_pass, e)
    Sentry.capture_exception(e, extra: { wallet_pass_id: wallet_pass_id })
  end

  private

  def record_failure(wallet_pass, error)
    wallet_pass&.update_columns(last_error: "#{error.class}: #{error.message}".first(500),
      sync_attempts: wallet_pass.sync_attempts + 1, updated_at: Time.current)
  end
end
