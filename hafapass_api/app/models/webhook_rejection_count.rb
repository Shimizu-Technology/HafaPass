# frozen_string_literal: true

# A counter of provider webhooks rejected before any receipt is stored. One row
# per provider, reason and five-minute bucket; never a payload, header or
# address. See Operations::WebhookRejections.
class WebhookRejectionCount < ApplicationRecord
  validates :provider, :reason, :bucket_started_at, presence: true
  validates :count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
