# frozen_string_literal: true

class Payout < ApplicationRecord
  belongs_to :organization
  belongs_to :event
  belongs_to :settlement
  belongs_to :connected_account
  encrypts :tax_information_tin
  self.filter_attributes += [:tax_information_tin]

  enum :status, { pending: 0, processing: 1, paid: 2, failed: 3, reversed: 4, held: 5 }, prefix: true

  validates :provider, :idempotency_key, :currency, presence: true
  validates :idempotency_key, uniqueness: true
  validates :provider_payout_id, uniqueness: { scope: :provider }, allow_blank: true
  validates :amount_cents, numericality: { only_integer: true, greater_than: 0 }
  validates :withheld_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :withholding_less_than_amount
  validates :currency, length: { is: 3 }
  validate :relationships_share_organization

  attr_readonly :organization_id, :event_id, :settlement_id, :connected_account_id,
    :provider, :idempotency_key, :amount_cents, :currency, :payee_snapshot, :payee_approval_digest,
    :tax_information_snapshot, :tax_information_tin, :tax_approval_digest

  def disbursement_cents
    amount_cents - withheld_cents
  end

  PAYEE_CHANGED_MESSAGE = "The payee on file differs from the approved payee shown. Confirm you wrote this " \
    "check to the approved payee before recording it as paid."
  TAX_APPROVAL_CHANGED_MESSAGE = "The W-9 or payout approval differs from the approved tax identity shown. " \
    "Confirm this payout was already sent to the approved payee shown above before recording it as paid."

  def self.tax_snapshot(record)
    return {} unless record&.certified_at

    record.safe_json.slice("legal_name", "business_name", "tax_classification", "tin_type", "mailing_address",
      "exempt_payee_code", "signer_name", "certified_at", "certification_version", "masked_tin").merge(
        "tin_last_four" => record.tin_last_four, "tax_information_id" => record.id,
        "tax_information_updated_at" => record.updated_at.iso8601(6))
  end

  def tax_approval_matches?
    snapshot = tax_information_snapshot.to_h
    return true if snapshot.blank? && withheld_cents.positive?
    tax = organization.organizer_tax_information
    snapshot.present? && tax.present? && snapshot["tax_information_id"] == tax.id &&
      snapshot["tax_information_updated_at"] == tax.updated_at.iso8601(6) &&
      tax_approval_digest.present? && tax_approval_digest == connected_account.reload.readiness_state_digest &&
      connected_account.payout_ready?
  end

  def serializable_hash(options = nil)
    super((options || {}).merge(except: Array(options&.dig(:except)) + ["tax_information_tin"]))
  end

  # A check is written to the payee this payout was approved for. Payee edits
  # are blocked while a check payout is in flight, so a difference only comes
  # from older data; recording it as paid then needs an explicit confirmation.
  def payee_matches_approval?
    return true unless provider == "check"

    payee_snapshot.present? && connected_account.check_payee == payee_snapshot
  end

  def may_reconcile_to?(new_status)
    {
      "pending" => %w[paid failed reversed],
      "processing" => %w[paid failed reversed],
      "held" => %w[paid failed reversed],
      "paid" => %w[reversed],
      "failed" => [],
      "reversed" => []
    }.fetch(status).include?(new_status.to_s)
  end

  private

  def withholding_less_than_amount
    errors.add(:withheld_cents, "must be less than the gross payout") if withheld_cents.to_i >= amount_cents.to_i
  end

  def relationships_share_organization
    ids = [event&.organization_id, settlement&.organization_id, connected_account&.organization_id].compact.uniq
    errors.add(:base, "Payout relationships must share an organization") if ids.any? && ids != [organization_id]
  end
end
