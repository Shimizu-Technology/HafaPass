# frozen_string_literal: true

class Payment < ApplicationRecord
  belongs_to :order
  has_one :stripe_fee_evidence, dependent: :restrict_with_error
  has_many :reconciliation_exceptions, dependent: :restrict_with_error
  has_many :payment_events, dependent: :restrict_with_error
  has_many :refunds, dependent: :restrict_with_error
  has_many :card_present_payment_attempts, dependent: :restrict_with_error

  enum :status, { pending: 0, succeeded: 1, failed: 2, cancelled: 3, partially_refunded: 4, refunded: 5 }

  # A missing environment predates the environment column. Only provider
  # evidence that explicitly says test/simulated may override that legacy default.
  scope :live_or_legacy_capture, -> {
    where(status: [:succeeded, :partially_refunded, :refunded])
      .where("provider_environment = 'live' OR (provider_environment IS NULL AND provider_payload->>'livemode' IS DISTINCT FROM 'false' AND provider_payload->>'simulated' IS DISTINCT FROM 'true')")
  }
  scope :nonlive_stripe, -> {
    where(provider: "stripe").where("provider_environment IN ('test', 'simulate') OR (provider_environment IS NULL AND (provider_payload->>'livemode' = 'false' OR provider_payload->>'simulated' = 'true'))")
  }

  validates :provider, :idempotency_key, :currency, presence: true
  validates :idempotency_key, uniqueness: true
  validates :provider_payment_id, uniqueness: { scope: :provider }, allow_nil: true
  validates :amount_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :currency, length: { is: 3 }

  validates :provider_environment, inclusion: { in: %w[simulate test live] }, allow_nil: true

  attr_readonly :provider_environment, :provider_platform_account_id, :provider_account_id, :order_id, :provider, :idempotency_key, :amount_cents, :currency

  def refunded_cents
    refunds.succeeded.sum(:amount_cents)
  end
end
