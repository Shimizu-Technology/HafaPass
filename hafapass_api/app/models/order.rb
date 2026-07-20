class Order < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :event
  belongs_to :promo_code, optional: true
  has_many :order_items, dependent: :restrict_with_error
  has_many :fee_components, dependent: :restrict_with_error
  has_many :inventory_holds, dependent: :restrict_with_error
  has_many :payments, dependent: :restrict_with_error
  has_many :refunds, dependent: :restrict_with_error
  has_many :tickets, dependent: :restrict_with_error
  has_one :promo_redemption, dependent: :restrict_with_error
  has_many :reconciliation_exceptions, dependent: :restrict_with_error

  enum :status, { pending: 0, completed: 1, refunded: 2, cancelled: 3, partially_refunded: 4, expired: 5 }

  validates :buyer_email, presence: true
  validates :buyer_name, presence: true
  validates :currency, presence: true, length: { is: 3 }
  validates :subtotal_cents, :service_fee_cents, :discount_cents, :total_cents, :refund_amount_cents,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :financial_components_balance

  def gross_cents
    subtotal_cents
  end

  def refunded_cents
    refunds.succeeded.sum(:amount_cents)
  end

  def net_cents
    total_cents - refunded_cents
  end

  def fee_cents
    fee_components.sum(:amount_cents)
  end

  def organizer_proceeds_cents
    order_items.sum(:organizer_proceeds_cents) - refunded_organizer_proceeds_cents
  end

  def refundable_cents
    committed_refunds = refunds.where(status: [:pending, :succeeded]).sum(:amount_cents)
    [total_cents - committed_refunds, 0].max
  end

  private

  def financial_components_balance
    return if [subtotal_cents, service_fee_cents, discount_cents, total_cents, refund_amount_cents].any?(&:nil?)

    expected_total = [subtotal_cents + service_fee_cents - discount_cents, 0].max
    errors.add(:total_cents, "must equal subtotal plus fees minus discount") unless total_cents == expected_total
    errors.add(:refund_amount_cents, "cannot exceed total") if refund_amount_cents > total_cents
  end

  def refunded_organizer_proceeds_cents
    RefundItem.joins(:refund)
      .where(refunds: { order_id: id, status: Refund.statuses[:succeeded] })
      .sum(:organizer_proceeds_cents)
  end
end
