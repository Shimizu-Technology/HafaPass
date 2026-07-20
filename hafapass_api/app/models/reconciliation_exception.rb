# frozen_string_literal: true

class ReconciliationException < ApplicationRecord
  belongs_to :order, optional: true
  belongs_to :payment, optional: true
  belongs_to :webhook_event, optional: true

  enum :status, { open: 0, resolved: 1 }

  validates :code, presence: true
  validates :expected_amount_cents, :actual_amount_cents,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true

  def resolve!
    update!(status: :resolved, resolved_at: Time.current)
  end
end
