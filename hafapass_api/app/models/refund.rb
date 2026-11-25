# frozen_string_literal: true

class Refund < ApplicationRecord
  belongs_to :order
  belongs_to :payment, optional: true

  # Rows on the order's sale, never those on a payment-scope never-fulfilled
  # capture (UnfulfilledCapture.excluding_isolated).
  scope :excluding_isolated_payments, -> { UnfulfilledCapture.excluding_isolated(self, :payment_id) }
  scope :excluding_repayment_fenced, -> { where("refunds.payment_id IS NULL OR NOT hafapass_fenced_payment(refunds.payment_id)") }
  belongs_to :requested_by, class_name: "User", optional: true
  belongs_to :repayment_operation, optional: true
  has_many :refund_items, dependent: :restrict_with_error
  has_many :refund_tickets, dependent: :restrict_with_error
  has_many :promoter_commission_entries, dependent: :restrict_with_error
  has_many :tickets, through: :refund_tickets

  enum :status, { pending: 0, succeeded: 1, failed: 2, cancelled: 3 }

  def organizer_ticket_selection?
    provider_payload["organizer_ticket_selection"] == true
  end

  def preserves_tickets?
    provider_payload["preserve_tickets"] == true
  end

  validates :provider, :idempotency_key, :currency, presence: true
  validates :idempotency_key, uniqueness: true
  validates :provider_refund_id, uniqueness: { scope: :provider }, allow_nil: true
  validates :amount_cents, numericality: { only_integer: true, greater_than: 0 }
  validates :currency, length: { is: 3 }

  after_save -> { Wallet::PassSync.tickets_changed(order.tickets.select(:id)) },
    if: -> { previously_new_record? || saved_change_to_status? }
  # A refund of a repayment operation carries its outcome to the operation
  # in the same transaction, whichever writer recorded it.
  after_save -> { Commerce::BuyerRepayment.record_outcome!(self) },
    if: -> { repayment_operation_id.present? && saved_change_to_status? && !pending? }
  after_commit :resume_event_cancellation_refunds,
    if: -> { saved_change_to_status? && (succeeded? || failed? || cancelled?) }

  def historical_observation?
    provider_payload["historical_observation"] == true
  end

  def resume_event_cancellation_refunds
    run = order.event.event_cancellation_refund_run
    EventCancellationRefundJob.perform_later(run.id) if run && run.items.where(order_id: order_id).exists?
  end

  attr_readonly :order_id, :payment_id, :requested_by_id, :provider, :idempotency_key, :amount_cents, :currency
end
