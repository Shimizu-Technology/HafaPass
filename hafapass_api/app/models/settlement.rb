# frozen_string_literal: true

class Settlement < ApplicationRecord
  MONEY_COLUMNS = %i[
    gross_cents discount_cents refund_cents net_cents platform_fee_cents processing_fee_cents
    organizer_proceeds_cents reserve_cents adjustment_cents payable_cents paid_cents negative_balance_cents
  ].freeze

  belongs_to :organization
  belongs_to :event
  has_many :settlement_items, dependent: :restrict_with_error
  has_many :payouts, dependent: :restrict_with_error

  enum :status, { draft: 0, finalized: 1 }, prefix: true

  validates :version, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :event_id }
  validates :source_digest, presence: true, uniqueness: { scope: :event_id }
  validates :currency, length: { is: 3 }
  validates :calculated_at, presence: true
  validates(*MONEY_COLUMNS - [:adjustment_cents], numericality: { only_integer: true, greater_than_or_equal_to: 0 })
  validates :adjustment_cents, numericality: { only_integer: true }
  validate :event_matches_organization

  before_update :prevent_finalized_mutation
  before_destroy :prevent_finalized_destruction

  def paid_or_processing_cents
    event.payouts.where(status: [:pending, :processing, :paid]).sum(:amount_cents)
  end

  def available_to_payout_cents
    [payable_cents - paid_or_processing_cents, 0].max
  end

  private

  def event_matches_organization
    return if event.nil? || event.organization_id == organization_id

    errors.add(:event, "must belong to the same organization")
  end

  def prevent_finalized_mutation
    return unless status_was == "finalized"

    errors.add(:base, "Finalized settlements are immutable")
    throw(:abort)
  end

  def prevent_finalized_destruction
    return unless status_finalized?

    errors.add(:base, "Finalized settlements are immutable")
    throw(:abort)
  end
end
