# frozen_string_literal: true

class CardPresentPaymentAttempt < ApplicationRecord
  belongs_to :organization
  belongs_to :event
  belongs_to :order
  belongs_to :payment
  belongs_to :card_present_account
  belongs_to :initiated_by_user, class_name: "User"

  enum :status, { initiated: 0, succeeded: 1, failed: 2, result_unknown: 3 }, prefix: true

  validates :provider, :idempotency_key, :external_payment_id, :currency, :initiated_at, presence: true
  validates :idempotency_key, uniqueness: true
  validates :external_payment_id, uniqueness: true
  validates :idempotency_key, length: { maximum: 255 }
  validates :external_payment_id, length: { maximum: 32 }
  validates :provider_payment_id, uniqueness: { scope: :provider }, allow_blank: true
  validates :amount_cents, numericality: { only_integer: true, greater_than: 0 }
  validates :currency, length: { is: 3 }
  validate :relationships_share_organization

  attr_readonly :organization_id, :event_id, :order_id, :payment_id, :card_present_account_id,
    :initiated_by_user_id, :provider, :idempotency_key, :external_payment_id, :amount_cents, :currency, :initiated_at

  before_destroy :prevent_destruction

  private

  def relationships_share_organization
    ids = [event&.organization_id, order&.event&.organization_id, card_present_account&.organization_id].compact.uniq
    errors.add(:base, "Card-present relationships must share an organization") if ids.any? && ids != [organization_id]
    errors.add(:payment, "must belong to the order") if payment && order && payment.order_id != order_id
  end

  def prevent_destruction
    errors.add(:base, "Card-present payment attempts cannot be destroyed")
    throw(:abort)
  end
end
