# frozen_string_literal: true

class RefundTicket < ApplicationRecord
  belongs_to :refund
  belongs_to :ticket

  scope :active, -> { where(released_at: nil) }

  validates :ticket_id, uniqueness: { conditions: -> { where(released_at: nil) } }, if: -> { released_at.nil? }
  validates :amount_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :ticket_belongs_to_refund_order

  private

  def ticket_belongs_to_refund_order
    return if refund.blank? || ticket.blank? || refund.order_id == ticket.order_id

    errors.add(:ticket, "must belong to the refunded order")
  end
end
