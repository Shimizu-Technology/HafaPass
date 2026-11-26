# frozen_string_literal: true

class Payment < ApplicationRecord
  encrypts :stripe_checkout_url

  belongs_to :order
  has_one :stripe_fee_evidence, dependent: :restrict_with_error
  has_many :reconciliation_exceptions, dependent: :restrict_with_error
  has_many :payment_events, dependent: :restrict_with_error
  has_many :refunds, dependent: :restrict_with_error
  has_many :card_present_payment_attempts, dependent: :restrict_with_error
  has_one :unfulfilled_capture, dependent: :restrict_with_error

  enum :status, { pending: 0, succeeded: 1, failed: 2, cancelled: 3, partially_refunded: 4, refunded: 5 }

  # A missing environment predates the environment column. Only provider
  # evidence that explicitly says test/simulated may override that legacy default.
  scope :live_or_legacy_capture, -> {
    where(status: [:succeeded, :partially_refunded, :refunded])
      .where("provider_environment = 'live' OR (provider_environment IS NULL AND provider_payload->>'livemode' IS DISTINCT FROM 'false' AND provider_payload->>'simulated' IS DISTINCT FROM 'true')")
  }
  # Live (or legacy non-test) USD Stripe captures that collected money into
  # HåfaPass's own account (design §4.4). The A2 finance readers share it.
  scope :live_agent_capture, -> {
    live_or_legacy_capture.where(provider: "stripe", currency: "usd")
      .where("LEFT(COALESCE(payments.provider_payment_id, ''), 4) <> 'sim_'")
      .where("payments.provider_payload->>'simulated' IS DISTINCT FROM 'true'")
      .where("payments.provider_payload->>'livemode' IS DISTINCT FROM 'false'")
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
  # Database-stamped when the payment is first captured, then immutable
  # (lib/financial_integrity.rb). Writers never supply it. Unlike succeeded_at,
  # which the legacy webhook backfill copies from order.completed_at, it is
  # the time HåfaPass actually recorded the capture.
  attr_readonly :capture_recorded_at

  # Captures that belong to the order's sale: everything except a payment-scope
  # never-fulfilled capture (UnfulfilledCapture.excluding_isolated).
  scope :excluding_isolated_captures, -> { UnfulfilledCapture.excluding_isolated(self, :id) }
  # Payments HåfaPass returns only through the repayment workflow (the
  # database fence's own predicate; design §6.2, §10.1).
  scope :excluding_repayment_fenced, -> { where("NOT hafapass_fenced_payment(payments.id)") }

  CAPTURED_STATUSES = %w[succeeded partially_refunded refunded].freeze

  # A refund or dispute notice can arrive before the payment is bound to its
  # intent (door Checkout) or before its capture is recorded. Whichever comes
  # first, replay the stored notice after commit (design §7.2). The gate never
  # depends on this callback: unreplayed evidence is checked under the locks.
  after_commit :replay_orphaned_provider_evidence, on: [:create, :update], if: :provider_evidence_may_apply?

  def refunded_cents
    refunds.succeeded.sum(:amount_cents)
  end

  def card_summary
    payload = provider_payload.to_h
    brand = payload["cardType"] || payload["card_brand"]
    last4 = payload["last4"] || payload["card_last4"]
    brand = nil unless brand.to_s.match?(/\A[a-zA-Z0-9 -]{1,24}\z/)
    last4 = nil unless last4.to_s.match?(/\A\d{4}\z/)
    { brand: brand, last4: last4 }
  end

  private

  def provider_evidence_may_apply?
    return false unless provider == "stripe" && provider_payment_id.present?

    (saved_change_to_provider_payment_id? ||
      (saved_change_to_status? && CAPTURED_STATUSES.include?(status) && CAPTURED_STATUSES.exclude?(status_before_last_save))) &&
      StripeWebhookProcessor.replayable_receipts(self).exists?
  end

  def replay_orphaned_provider_evidence
    ProviderEvidenceReplayJob.perform_later(id)
  end
end
