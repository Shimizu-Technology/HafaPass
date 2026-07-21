# frozen_string_literal: true

class Refund < ApplicationRecord
  belongs_to :order
  belongs_to :payment, optional: true
  belongs_to :requested_by, class_name: "User", optional: true
  has_many :refund_items, dependent: :restrict_with_error
  has_many :refund_tickets, dependent: :restrict_with_error
  has_many :promoter_commission_entries, dependent: :restrict_with_error
  has_many :tickets, through: :refund_tickets

  enum :status, { pending: 0, succeeded: 1, failed: 2, cancelled: 3 }

  validates :provider, :idempotency_key, :currency, presence: true
  validates :idempotency_key, uniqueness: true
  validates :provider_refund_id, uniqueness: { scope: :provider }, allow_nil: true
  validates :amount_cents, numericality: { only_integer: true, greater_than: 0 }
  validates :currency, length: { is: 3 }

  attr_readonly :order_id, :payment_id, :requested_by_id, :provider, :idempotency_key, :amount_cents, :currency
end
