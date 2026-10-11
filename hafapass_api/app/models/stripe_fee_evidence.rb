# frozen_string_literal: true

class StripeFeeEvidence < ApplicationRecord
  belongs_to :payment
  belongs_to :fee_component, optional: true

  enum :status, { pending: "pending", verified: "verified", review_required: "review_required" }, prefix: true
  validates :context_digest, presence: true
  validates :fee_component, :provider_charge_id, :provider_balance_transaction_id, :evidence_digest,
    :currency, :verified_at, presence: true, if: :status_verified?
  validate :verified_component_matches
  attr_readonly :payment_id, :context_digest

  private

  def verified_component_matches
    return unless status_verified? && fee_component
    unless fee_component.order_id == payment.order_id && fee_component.kind == "processing" &&
        !fee_component.estimated? && fee_component.currency == currency && fee_component.amount_cents == fee_cents &&
        fee_component.provider_reference == provider_balance_transaction_id
      errors.add(:fee_component, "must match the verified payment and provider fee")
    end
  end
end
