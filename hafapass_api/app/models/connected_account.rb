# frozen_string_literal: true

class ConnectedAccount < ApplicationRecord
  PROVIDERS = %w[paypal manual stripe legacy_manual check].freeze
  CHECK_DELIVERY_METHODS = %w[mail pickup].freeze
  MANUAL_PROVIDERS = %w[check manual].freeze
  encrypts :bank_account_number
  self.filter_attributes += [:bank_account_number]

  belongs_to :organization
  has_many :payouts, dependent: :restrict_with_error
  has_many :payment_readiness_reviews, dependent: :restrict_with_error
  has_many :live_money_proof_authorizations, dependent: :restrict_with_error
  has_many :live_money_proof_reviews, dependent: :restrict_with_error

  enum :status, {
    pending: 0, onboarding: 1, requirements_due: 2, ready: 3, restricted: 4, disabled: 5
  }, prefix: true

  validates :provider, inclusion: { in: PROVIDERS }, uniqueness: { scope: :organization_id }
  validates :provider_account_id, uniqueness: { scope: :provider }, allow_blank: true
  validates :country, :currency, presence: true
  validates :currency, length: { is: 3 }
  validate :check_payee_details, if: -> { provider == "check" }

  def payout_ready?
    organization.organizer_tax_information&.certified_at.present? && externally_ready? && active_payment_readiness_approval.present?
  end

  def externally_ready?
    !status_disabled? && charges_enabled? && payouts_enabled? && details_submitted? && provider_requirements_due.blank?
  end

  def provider_requirements_due
    Array(requirements_due) - [ConnectedAccounts::Manager::INDEPENDENT_APPROVAL_REQUIREMENT]
  end

  def active_payment_readiness_approval(at: Time.current)
    revoked_approval_ids = payment_readiness_reviews.revocations.select(:parent_review_id)
    payment_readiness_reviews.approvals
      .where("effective_at <= ? AND expires_at > ?", at, at)
      .where(provider_state_digest: readiness_state_digest)
      .where.not(id: revoked_approval_ids)
      .order(created_at: :desc)
      .first
  end

  def latest_payment_readiness_approval
    payment_readiness_reviews.approvals.order(created_at: :desc).first
  end

  def pending_payment_readiness_submission
    decided_submission_ids = payment_readiness_reviews.where(decision: [:approval, :rejection]).select(:parent_review_id)
    payment_readiness_reviews.decision_submission
      .where("expires_at > ?", Time.current)
      .where.not(id: decided_submission_ids)
      .order(created_at: :desc)
      .first
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
    # Where money goes is part of what an approval covers. Accounts without
    # payee details (every account before checks existed) keep their digest.
    payload[:payout_details] = canonicalize_readiness_value(payout_details) if payout_details.present?
    Digest::SHA256.hexdigest(payload.to_json)
  end

  def check_payee
    return {} unless provider == "check"

    payout_details.to_h.slice("payee_name", "delivery_method", "mailing_address", "pickup_note", "memo")
  end

  def manual_payout?
    MANUAL_PROVIDERS.include?(provider)
  end

  # Full account numbers are encrypted at rest and never serialized or audited.
  def safe_payout_details
    return check_payee if provider == "check"
    return {} unless provider == "manual"

    masked = if bank_account_number.blank?
      nil
    elsif bank_account_number.length <= 4
      "••••"
    else
      "•••• #{bank_account_number.last(4)}"
    end
    payout_details.to_h.slice("bank_name", "account_holder_name").merge("masked_account" => masked)
  end

  def manual_payout_missing
    missing = []
    missing << "W-9 not certified yet" unless organization.organizer_tax_information&.certified_at.present?
    complete = if provider == "check"
      check_payee["payee_name"].present? && CHECK_DELIVERY_METHODS.include?(check_payee["delivery_method"]) &&
        (check_payee["delivery_method"] == "pickup" || check_payee["mailing_address"].present?)
    elsif provider == "manual"
      payout_details.to_h.values_at("bank_name", "account_holder_name").all?(&:present?) && bank_account_number.present?
    end
    missing << "Payout details incomplete" unless complete
    missing << "Payout method is disabled" if status_disabled?
    missing
  end

  private

  def check_payee_details
    unless payout_details.is_a?(Hash)
      errors.add(:payout_details, "are invalid")
      return
    end

    details = payout_details
    errors.add(:payout_details, "need the name to write on the check") if details["payee_name"].to_s.strip.blank?
    unless CHECK_DELIVERY_METHODS.include?(details["delivery_method"])
      errors.add(:payout_details, "need a delivery choice: mail or pickup")
    end
    if details["delivery_method"] == "mail" && details["mailing_address"].to_s.strip.blank?
      errors.add(:payout_details, "need a mailing address for mailed checks")
    end
    if details.values.any? { |value| value.to_s.length > 1000 }
      errors.add(:payout_details, "are too long")
    end
  end

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
