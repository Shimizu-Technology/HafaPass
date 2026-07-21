# frozen_string_literal: true

class ConnectedAccount < ApplicationRecord
  PROVIDERS = %w[paypal manual stripe legacy_manual].freeze

  belongs_to :organization
  has_many :payouts, dependent: :restrict_with_error
  has_many :payment_readiness_reviews, dependent: :restrict_with_error

  enum :status, {
    pending: 0, onboarding: 1, requirements_due: 2, ready: 3, restricted: 4, disabled: 5
  }, prefix: true

  validates :provider, inclusion: { in: PROVIDERS }, uniqueness: { scope: :organization_id }
  validates :provider_account_id, uniqueness: { scope: :provider }, allow_blank: true
  validates :country, :currency, presence: true
  validates :currency, length: { is: 3 }

  def payout_ready?
    externally_ready? && active_payment_readiness_approval.present?
  end

  def externally_ready?
    !status_disabled? && charges_enabled? && payouts_enabled? && details_submitted? && provider_requirements_due.blank?
  end

  def provider_requirements_due
    Array(requirements_due) - [ConnectedAccounts::Manager::INDEPENDENT_APPROVAL_REQUIREMENT]
  end

  def active_payment_readiness_approval(at: Time.current)
    payment_readiness_reviews.approvals.order(created_at: :desc).detect { |review| review.active?(at: at) }
  end

  def latest_payment_readiness_approval
    payment_readiness_reviews.approvals.order(created_at: :desc).first
  end

  def pending_payment_readiness_submission
    payment_readiness_reviews.decision_submission.where("expires_at > ?", Time.current).order(created_at: :desc).detect do |review|
      !review.child_reviews.where(decision: [:approval, :rejection]).exists?
    end
  end

  def readiness_state_digest
    Digest::SHA256.hexdigest({
      readiness_revision: readiness_revision,
      provider_configuration_digest: provider_configuration_digest
    }.to_json)
  end

  def provider_configuration_digest
    payload = {
      provider: provider,
      provider_account_id: provider_account_id,
      country: country,
      currency: currency,
      charges_enabled: charges_enabled,
      payouts_enabled: payouts_enabled,
      details_submitted: details_submitted,
      disabled: status_disabled?,
      provider_requirements_due: provider_requirements_due.sort,
      capabilities: canonicalize_readiness_value(capabilities)
    }
    Digest::SHA256.hexdigest(payload.to_json)
  end

  private

  def canonicalize_readiness_value(value)
    case value
    when Hash
      value.stringify_keys.sort.to_h.transform_values { |item| canonicalize_readiness_value(item) }
    when Array
      value.map { |item| canonicalize_readiness_value(item) }
    else
      value
    end
  end
end
