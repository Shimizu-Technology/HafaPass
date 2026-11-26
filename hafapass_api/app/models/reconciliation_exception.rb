# frozen_string_literal: true

class ReconciliationException < ApplicationRecord
  belongs_to :order, optional: true
  belongs_to :payment, optional: true
  belongs_to :webhook_event, optional: true

  enum :status, { open: 0, resolved: 1 }

  # Stamped by the database on insert from the payment's overlap capture, or
  # for an over-return from its P4 proof check (hafapass_exception_hold_start),
  # and never changed.
  attr_readonly :hold_started_at, :proof_checked_at

  validates :code, presence: true
  validates :expected_amount_cents, :actual_amount_cents,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true

  def resolve!
    update!(status: :resolved, resolved_at: Time.current)
  end

  # An evidence hold (FinancialIntegrity::EVIDENCE_HOLD_CODES) closes only
  # through a path that recorded its evidence; the database refuses any
  # other open -> resolved change, including a note-only resolution.
  def resolve_with_evidence!
    self.class.transaction do
      FinancialIntegrity.with_evidence(:evidence_resolution, id) { resolve! }
    end
  end

  def evidence_hold?
    FinancialIntegrity::EVIDENCE_HOLD_CODES.include?(code)
  end
end
