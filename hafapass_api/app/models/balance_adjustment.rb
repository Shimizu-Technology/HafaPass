# frozen_string_literal: true

class BalanceAdjustment < ApplicationRecord
  KINDS = %w[reserve_hold reserve_release dispute_loss dispute_recovery processing_fee manual_credit manual_debit payout_reversal].freeze

  belongs_to :organization
  belongs_to :event, optional: true
  belongs_to :order, optional: true
  belongs_to :dispute, optional: true
  belongs_to :created_by_user, class_name: "User", optional: true
  belongs_to :reversed_by_user, class_name: "User", optional: true
  belongs_to :reversal_of, class_name: "BalanceAdjustment", optional: true
  has_one :reversal, class_name: "BalanceAdjustment", foreign_key: :reversal_of_id, dependent: :restrict_with_error

  enum :status, { pending: 0, posted: 1, reversed: 2 }, prefix: true

  validates :kind, inclusion: { in: KINDS }
  validates :amount_cents, numericality: { only_integer: true, other_than: 0 }
  validates :currency, length: { is: 3 }
  validates :reason, :effective_at, presence: true
  validate :event_matches_organization
  validate :order_matches_organization
  validate :dispute_matches_organization

  scope :effective, -> { status_posted.where("effective_at <= ?", Time.current) }

  before_update :protect_posted_financial_fields
  before_destroy :prevent_destruction

  private

  def event_matches_organization
    return if event.nil? || event.organization_id == organization_id

    errors.add(:event, "must belong to the same organization")
  end

  def order_matches_organization
    return if order.nil? || order.event.organization_id == organization_id

    errors.add(:order, "must belong to the same organization")
  end

  def dispute_matches_organization
    return if dispute.nil? || dispute.order.event.organization_id == organization_id

    errors.add(:dispute, "must belong to the same organization")
  end

  def protect_posted_financial_fields
    return unless status_was == "posted"

    permitted_changes = %w[status reversed_by_user_id updated_at]
    return if changes.keys.all? { |attribute| permitted_changes.include?(attribute) }

    errors.add(:base, "Posted adjustments are immutable; create a reversal")
    throw(:abort)
  end

  def prevent_destruction
    errors.add(:base, "Financial adjustments cannot be deleted; create a reversal")
    throw(:abort)
  end
end
