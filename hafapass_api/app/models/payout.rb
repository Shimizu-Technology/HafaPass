# frozen_string_literal: true

class Payout < ApplicationRecord
  belongs_to :organization
  belongs_to :event
  belongs_to :settlement
  belongs_to :connected_account

  enum :status, { pending: 0, processing: 1, paid: 2, failed: 3, reversed: 4 }, prefix: true

  validates :provider, :idempotency_key, :currency, presence: true
  validates :idempotency_key, uniqueness: true
  validates :provider_payout_id, uniqueness: { scope: :provider }, allow_blank: true
  validates :amount_cents, numericality: { only_integer: true, greater_than: 0 }
  validates :currency, length: { is: 3 }
  validate :relationships_share_organization

  attr_readonly :organization_id, :event_id, :settlement_id, :connected_account_id,
    :provider, :idempotency_key, :amount_cents, :currency

  def may_reconcile_to?(new_status)
    {
      "pending" => %w[paid failed reversed],
      "processing" => %w[paid failed reversed],
      "paid" => %w[reversed],
      "failed" => [],
      "reversed" => []
    }.fetch(status).include?(new_status.to_s)
  end

  private

  def relationships_share_organization
    ids = [event&.organization_id, settlement&.organization_id, connected_account&.organization_id].compact.uniq
    errors.add(:base, "Payout relationships must share an organization") if ids.any? && ids != [organization_id]
  end
end
