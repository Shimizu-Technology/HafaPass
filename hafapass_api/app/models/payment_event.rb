# frozen_string_literal: true

class PaymentEvent < ApplicationRecord
  include AppendOnlyRecord

  belongs_to :payment, optional: true
  belongs_to :webhook_event

  validates :event_type, presence: true
  validates :webhook_event_id, uniqueness: true
  validates :amount_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :currency, length: { is: 3 }, allow_nil: true
end
