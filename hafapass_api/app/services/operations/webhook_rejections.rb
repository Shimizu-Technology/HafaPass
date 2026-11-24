# frozen_string_literal: true

module Operations
  # Counts provider webhooks rejected before a receipt is stored, so a wrong
  # signing secret (every delivery fails verification) is visible: no
  # WebhookEvent row exists for those. Only a count per five-minute bucket is
  # kept.
  #
  # Reasons: invalid_signature (a Stripe-shaped signature header that failed
  # verification: the signal for a wrong or rotated secret), secret_missing
  # (signed delivery but no secret configured for its mode), signature_missing
  # (no signature header at all: usually internet noise, recorded but not
  # alerted on).
  module WebhookRejections
    BUCKET = 5.minutes
    ALERT_REASONS = %w[invalid_signature secret_missing].freeze
    REASONS = (ALERT_REASONS + %w[signature_missing]).freeze

    module_function

    # Never raises: counting must not change the response Stripe sees.
    def record!(provider:, reason:, at: Time.current)
      return unless REASONS.include?(reason)

      bucket = Time.zone.at((at.to_i / BUCKET.to_i) * BUCKET.to_i)
      now = Time.current
      WebhookRejectionCount.upsert({ provider: provider, reason: reason, bucket_started_at: bucket, count: 1,
        created_at: now, updated_at: now }, unique_by: :index_webhook_rejection_counts_on_bucket,
        on_duplicate: Arel.sql("count = webhook_rejection_counts.count + 1, updated_at = EXCLUDED.updated_at"))
    rescue StandardError => e
      Rails.logger.error({ event: "webhook_rejection_count_failed", error_class: e.class.name }.to_json)
    end

    def count(provider:, since:, reasons: ALERT_REASONS)
      WebhookRejectionCount.where(provider: provider, reason: reasons, bucket_started_at: (since - BUCKET + 1.second)..).sum(:count)
    end
  end
end
