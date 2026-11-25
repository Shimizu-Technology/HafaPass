# frozen_string_literal: true

# One outbound refund operation that returns a never-fulfilled capture to its
# buyer (docs/design/never-fulfilled-captures.md §6.3). Identity is
# append-only and the state moves forward only; the database trigger
# (lib/financial_integrity.rb, REPAYMENT_SQL) enforces both, the contiguous
# sequence, the exact key per sequence, and "a new operation only after every
# earlier one is verified terminal". Commerce::BuyerRepayment is the only
# writer.
#
# States: reserved (amount fixed under the order lock, never sent),
# submitting (the gate counted one sender; the POST may be in flight),
# unknown (a send finished without a verifiable result), succeeded,
# failed_terminal (verified failure, cancellation, or a reservation that never
# passed the gate).
class RepaymentOperation < ApplicationRecord
  STATES = FinancialIntegrity::OPERATION_STATES
  OPEN_STATES = %w[reserved submitting unknown].freeze
  TERMINAL_STATES = %w[succeeded failed_terminal].freeze
  SOURCES = %w[automatic admin_late_capture admin_order_refund fraud_warning evaluator queue_retry adoption].freeze

  belongs_to :unfulfilled_capture, foreign_key: :never_fulfilled_capture_id, inverse_of: :repayment_operations
  belongs_to :payment
  belongs_to :refund, optional: true

  scope :open_states, -> { where(state: OPEN_STATES) }
  scope :in_sequence, -> { order(:sequence) }

  validates :state, inclusion: { in: STATES }
  validates :source, inclusion: { in: SOURCES }
  validates :amount_cents, numericality: { only_integer: true, greater_than: 0 }

  attr_readonly :never_fulfilled_capture_id, :payment_id, :sequence, :amount_cents, :currency,
    :idempotency_key, :source, :adopted

  def self.key_for(payment_id, sequence)
    base = Commerce::LateCaptureRefund.idempotency_key(Payment.new(id: payment_id))
    sequence == 1 ? base : "#{base}:op:#{sequence}"
  end

  def open?
    OPEN_STATES.include?(state)
  end

  def terminal?
    TERMINAL_STATES.include?(state)
  end
end
