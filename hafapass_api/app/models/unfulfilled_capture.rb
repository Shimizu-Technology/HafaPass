# frozen_string_literal: true

# One captured payment HåfaPass did not fulfil (docs/design/never-fulfilled-captures.md §4).
# The table is append-only and its ownership rules live in database triggers
# (lib/financial_integrity.rb); these validations only give early feedback.
# Commerce::NeverFulfilledCapture stays the reader module until A3, hence the
# different model name.
#
# capture_scope "order": no capture on the order fulfilled it; the database
# sets orders.never_fulfilled_at from the first such row. "payment": a
# distinct second capture on an order that orders.fulfilled_by_payment_id
# says another payment fulfilled; the order stays fulfilled and unmarked.
class UnfulfilledCapture < ApplicationRecord
  self.table_name = "never_fulfilled_captures"

  CAPTURE_SCOPES = %w[order payment].freeze
  CODES = (Commerce::LateCaptureRefund::CODES + %w[unfulfilled_second_capture event_not_eligible]).freeze
  BEARERS = %w[platform organizer].freeze
  ALLOCATION_POLICIES = %w[item_record cumulative_pro_rata].freeze
  PROVENANCES = %w[lifecycle backfill].freeze

  belongs_to :order
  belongs_to :payment

  validates :capture_scope, inclusion: { in: CAPTURE_SCOPES }
  validates :code, inclusion: { in: CODES }
  validates :processing_bearer, :dispute_fee_bearer, inclusion: { in: BEARERS }
  validates :allocation_policy, inclusion: { in: ALLOCATION_POLICIES }
  validates :provenance, inclusion: { in: PROVENANCES }
  validates :policy_version, :currency, presence: true
  validate :payment_belongs_to_order

  def readonly?
    persisted? || super
  end

  def order_scope?
    capture_scope == "order"
  end

  def payment_scope?
    capture_scope == "payment"
  end

  private

  def payment_belongs_to_order
    errors.add(:payment, "must belong to the classified order") if payment && payment.order_id != order_id
  end
end
