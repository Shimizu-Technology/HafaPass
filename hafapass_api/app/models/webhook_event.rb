# frozen_string_literal: true

class WebhookEvent < ApplicationRecord
  has_one :payment_event, dependent: :restrict_with_error
  has_many :reconciliation_exceptions, dependent: :restrict_with_error

  enum :status, { received: 0, processing: 1, processed: 2, failed: 3, ignored: 4 }

  validates :provider, :provider_event_id, :event_type, presence: true
  validates :provider_event_id, uniqueness: { scope: :provider }
  validates :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  attr_readonly :provider, :provider_event_id, :event_type, :payload, :provider_created_at
end
