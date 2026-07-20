# frozen_string_literal: true

class Payment < ApplicationRecord
  belongs_to :order
  has_many :payment_events, dependent: :restrict_with_error
  has_many :refunds, dependent: :restrict_with_error

  enum :status, { pending: 0, succeeded: 1, failed: 2, cancelled: 3, partially_refunded: 4, refunded: 5 }

  validates :provider, :idempotency_key, :currency, presence: true
  validates :idempotency_key, uniqueness: true
  validates :provider_payment_id, uniqueness: { scope: :provider }, allow_nil: true
  validates :amount_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :currency, length: { is: 3 }

  attr_readonly :order_id, :provider, :idempotency_key, :amount_cents, :currency

  def refunded_cents
    refunds.succeeded.sum(:amount_cents)
  end
end
