# frozen_string_literal: true

class Dispute < ApplicationRecord
  belongs_to :order
  belongs_to :payment, optional: true

  enum :status, { open: 0, won: 1, lost: 2 }

  validates :provider, :provider_dispute_id, :currency, :opened_at, presence: true
  validates :provider_dispute_id, uniqueness: { scope: :provider }
  validates :amount_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :currency, length: { is: 3 }

  after_save -> { Wallet::PassSync.tickets_changed(order.tickets.select(:id)) },
    if: -> { previously_new_record? || saved_change_to_status? }
  after_commit :resume_event_cancellation_refunds, if: :saved_change_to_status?

  def resume_event_cancellation_refunds
    run = order.event.event_cancellation_refund_run
    EventCancellationRefundJob.perform_later(run.id) if run && run.items.where(order_id: order_id).exists?
  end

  attr_readonly :order_id, :payment_id, :provider, :provider_dispute_id, :amount_cents, :currency, :opened_at
end
